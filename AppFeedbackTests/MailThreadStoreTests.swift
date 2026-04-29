import XCTest
import SwiftData
@testable import AppFeedback

@MainActor
final class MailThreadStoreTests: XCTestCase {

    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(
            for: MailThread.self, MailMessage.self, MailAttachment.self,
                MailAttachmentLocal.self, MailAccountLocalState.self,
            configurations: config
        )
        return ModelContext(container)
    }

    // MARK: - Helpers

    private func makeParsed(
        uid: UInt32 = 1,
        folder: String = "INBOX",
        uidValidity: UInt32 = 100,
        messageID: String,
        inReplyTo: String? = nil,
        references: [String] = [],
        from: String = "sender@example.com",
        subject: String = "Test Subject",
        date: Date = Date(),
        attachments: [ParsedAttachmentMeta] = []
    ) -> ParsedInboundMessage {
        ParsedInboundMessage(
            uid: uid,
            folder: folder,
            uidValidity: uidValidity,
            messageID: messageID,
            inReplyTo: inReplyTo,
            references: references,
            fromAddress: from,
            fromName: nil,
            toAddresses: ["to@example.com"],
            ccAddresses: [],
            date: date,
            subject: subject,
            bodyPlain: "Body",
            bodyHTML: nil,
            attachments: attachments
        )
    }

    // MARK: - Test 1: recordInbound is idempotent on duplicate messageID

    func test_recordInbound_deduplicatesByMessageID() throws {
        let context = try makeContext()
        let store = MailThreadStore(context: context)

        let parsed = makeParsed(messageID: "<msg1@example.com>")
        let first = store.recordInbound(message: parsed)
        let second = store.recordInbound(message: parsed)

        XCTAssertNotNil(first, "First call should return a message")
        XCTAssertNil(second, "Second call with same messageID should return nil")

        let rows = try context.fetch(FetchDescriptor<MailMessage>())
        XCTAssertEqual(rows.count, 1, "Only one MailMessage row should exist")
    }

    // MARK: - Test 2: recordInbound with inReplyTo appends to existing thread

    func test_recordInbound_inReplyTo_appendsToExistingThread() throws {
        let context = try makeContext()
        let store = MailThreadStore(context: context)

        // Record an outbound message first
        let outbound = store.recordOutbound(
            messageID: "<outbound1@example.com>",
            repoOwner: "owner", repoName: "repo", issueNumber: 42,
            from: "me@example.com", fromName: "Me",
            to: ["user@example.com"], cc: [],
            subject: "Issue #42",
            bodyPlain: "Hello", bodyHTML: nil,
            date: Date(timeIntervalSinceNow: -100),
            replyHeaders: nil
        )
        let originalThread = outbound.thread
        XCTAssertNotNil(originalThread)

        // Record an inbound reply referencing the outbound
        let inbound = store.recordInbound(message: makeParsed(
            messageID: "<reply1@example.com>",
            inReplyTo: "<outbound1@example.com>"
        ))

        XCTAssertNotNil(inbound, "Should return inserted message")
        XCTAssertEqual(inbound?.thread?.id, originalThread?.id, "Reply should be on same thread")

        let threads = try context.fetch(FetchDescriptor<MailThread>())
        XCTAssertEqual(threads.count, 1, "Should still be only one thread")
    }

    // MARK: - Test 3: recordInbound with no header match creates orphan thread

    func test_recordInbound_noMatch_createsOrphanThread() throws {
        let context = try makeContext()
        let store = MailThreadStore(context: context)

        let inbound = store.recordInbound(message: makeParsed(
            messageID: "<orphan@example.com>",
            inReplyTo: nil,
            references: []
        ))

        XCTAssertNotNil(inbound)
        XCTAssertEqual(inbound?.thread?.issueNumber, 0, "Orphan thread should have issueNumber == 0")

        let threads = try context.fetch(FetchDescriptor<MailThread>())
        XCTAssertEqual(threads.count, 1)
    }

    // MARK: - Test 4: recordOutbound creates thread with deduped participants

    func test_recordOutbound_createsThreadWithDeduplicatedParticipants() throws {
        let context = try makeContext()
        let store = MailThreadStore(context: context)

        let msg = store.recordOutbound(
            messageID: "<out1@example.com>",
            repoOwner: "owner", repoName: "repo", issueNumber: 1,
            from: "me@example.com", fromName: "Me",
            to: ["a@example.com", "b@example.com"], cc: ["me@example.com", "b@example.com"],
            subject: "Hello",
            bodyPlain: "Body", bodyHTML: nil,
            date: Date(),
            replyHeaders: nil
        )

        let thread = msg.thread
        XCTAssertNotNil(thread)

        // me@example.com appears in from, cc; b@example.com appears in to and cc
        // Expected unique set: me@example.com, a@example.com, b@example.com
        let participants = thread?.participants ?? []
        XCTAssertEqual(participants.count, 3, "Participants should be deduped")
        XCTAssertTrue(participants.contains("me@example.com"))
        XCTAssertTrue(participants.contains("a@example.com"))
        XCTAssertTrue(participants.contains("b@example.com"))
    }

    // MARK: - Test 5: recordOutbound with replyHeaders.inReplyTo appends to existing thread

    func test_recordOutbound_withReplyHeaders_appendsToExistingThread() throws {
        let context = try makeContext()
        let store = MailThreadStore(context: context)

        // Create initial message/thread
        let first = store.recordOutbound(
            messageID: "<first@example.com>",
            repoOwner: "owner", repoName: "repo", issueNumber: 5,
            from: "me@example.com", fromName: nil,
            to: ["user@example.com"], cc: [],
            subject: "Thread start",
            bodyPlain: "First", bodyHTML: nil,
            date: Date(timeIntervalSinceNow: -200),
            replyHeaders: nil
        )
        let originalThread = first.thread
        XCTAssertNotNil(originalThread)

        // Create a reply using replyHeaders
        let replyHeaders = ReplyHeaderBuilder.Output(
            inReplyTo: "<first@example.com>",
            references: ["<first@example.com>"]
        )
        let second = store.recordOutbound(
            messageID: "<second@example.com>",
            repoOwner: "owner", repoName: "repo", issueNumber: 5,
            from: "me@example.com", fromName: nil,
            to: ["user@example.com"], cc: [],
            subject: "Re: Thread start",
            bodyPlain: "Second", bodyHTML: nil,
            date: Date(timeIntervalSinceNow: -100),
            replyHeaders: replyHeaders
        )

        XCTAssertEqual(second.thread?.id, originalThread?.id, "Reply should land on the same thread")

        let threads = try context.fetch(FetchDescriptor<MailThread>())
        XCTAssertEqual(threads.count, 1, "Should still be exactly one thread")
    }

    // MARK: - Test 9: threads(forIssue:) returns only matching threads sorted by lastMessageAt desc

    func test_threads_forIssue_returnsMatchingSortedByDateDesc() throws {
        let context = try makeContext()
        let store = MailThreadStore(context: context)

        let now = Date()
        let earlier = now.addingTimeInterval(-3600)

        // Two threads for issue #10
        let m1 = store.recordOutbound(
            messageID: "<t1@example.com>",
            repoOwner: "org", repoName: "repo", issueNumber: 10,
            from: "a@x.com", fromName: nil,
            to: ["b@x.com"], cc: [],
            subject: "First",
            bodyPlain: "First", bodyHTML: nil,
            date: earlier,
            replyHeaders: nil
        )
        let m2 = store.recordOutbound(
            messageID: "<t2@example.com>",
            repoOwner: "org", repoName: "repo", issueNumber: 10,
            from: "c@x.com", fromName: nil,
            to: ["d@x.com"], cc: [],
            subject: "Second",
            bodyPlain: "Second", bodyHTML: nil,
            date: now,
            replyHeaders: nil
        )
        // One thread for different issue
        _ = store.recordOutbound(
            messageID: "<t3@example.com>",
            repoOwner: "org", repoName: "repo", issueNumber: 99,
            from: "e@x.com", fromName: nil,
            to: ["f@x.com"], cc: [],
            subject: "Other",
            bodyPlain: "Other", bodyHTML: nil,
            date: now,
            replyHeaders: nil
        )

        let result = store.threads(forIssue: (owner: "org", repo: "repo", number: 10))
        XCTAssertEqual(result.count, 2, "Should return exactly 2 threads for issue #10")

        // Sorted descending by lastMessageAt — thread with 'now' comes first
        XCTAssertGreaterThanOrEqual(
            result[0].lastMessageAt, result[1].lastMessageAt,
            "Threads should be sorted by lastMessageAt descending"
        )

        // Verify all returned threads belong to issue #10
        for thread in result {
            XCTAssertEqual(thread.issueRepoOwner, "org")
            XCTAssertEqual(thread.issueRepoName, "repo")
            XCTAssertEqual(thread.issueNumber, 10)
        }

        // Keep compiler happy — m1 and m2 are used for their side effects
        _ = m1
        _ = m2
    }

    // MARK: - Test 10: recordInbound with attachments inserts MailAttachment rows

    func test_recordInbound_insertsAttachmentRows() throws {
        let context = try makeContext()
        let store = MailThreadStore(context: context)

        let attachmentMeta = [
            ParsedAttachmentMeta(partID: "1.2", filename: "doc.pdf", mimeType: "application/pdf", sizeBytes: 1024),
            ParsedAttachmentMeta(partID: "1.3", filename: "image.png", mimeType: "image/png", sizeBytes: 2048)
        ]

        let parsed = makeParsed(
            messageID: "<with-attachments@example.com>",
            attachments: attachmentMeta
        )

        let msg = store.recordInbound(message: parsed)
        XCTAssertNotNil(msg)

        let attachments = msg?.attachments ?? []
        XCTAssertEqual(attachments.count, 2, "Should have 2 attachment rows")

        let filenames = attachments.map(\.filename).sorted()
        XCTAssertEqual(filenames, ["doc.pdf", "image.png"])

        let partIDs = attachments.map(\.partID).sorted()
        XCTAssertEqual(partIDs, ["1.2", "1.3"])

        // Verify persisted
        let rows = try context.fetch(FetchDescriptor<MailAttachment>())
        XCTAssertEqual(rows.count, 2)
    }

    // MARK: - Test 11: recordInbound resolves thread via references chain (no inReplyTo)

    func test_recordInbound_referencesChain_appendsToExistingThread() throws {
        let context = try makeContext()
        let store = MailThreadStore(context: context)

        // Create an existing message/thread
        let existing = store.recordOutbound(
            messageID: "<old@x>",
            repoOwner: "owner", repoName: "repo", issueNumber: 7,
            from: "a@x.com", fromName: nil,
            to: ["b@x.com"], cc: [],
            subject: "Original",
            bodyPlain: "Original body", bodyHTML: nil,
            date: Date(timeIntervalSinceNow: -500),
            replyHeaders: nil
        )
        let originalThread = existing.thread
        XCTAssertNotNil(originalThread)

        // Record an inbound with NO inReplyTo, but references contains the existing messageID
        let inbound = store.recordInbound(message: makeParsed(
            messageID: "<new-via-refs@x>",
            inReplyTo: nil,
            references: ["<old@x>"]
        ))

        XCTAssertNotNil(inbound, "Should return an inserted message")
        XCTAssertEqual(inbound?.thread?.id, originalThread?.id,
                       "Message resolved via references should land on the same thread")

        let threads = try context.fetch(FetchDescriptor<MailThread>())
        XCTAssertEqual(threads.count, 1, "Should still be only one thread")

        XCTAssertEqual(inbound?.thread?.matchSource, .header,
                       "matchSource should be .header when resolved via references chain")
    }

    // MARK: - Test 13: deleting a MailThread cascades to MailMessage and MailAttachment rows

    func test_threadDelete_cascadesToMessages() throws {
        let context = try makeContext()
        let store = MailThreadStore(context: context)

        // Insert a thread with a message that has one attachment
        let attachmentMeta = [
            ParsedAttachmentMeta(partID: "2.1", filename: "file.txt", mimeType: "text/plain", sizeBytes: 512)
        ]
        let msg = store.recordInbound(message: makeParsed(
            messageID: "<cascade-test@example.com>",
            attachments: attachmentMeta
        ))
        XCTAssertNotNil(msg)

        let thread = msg!.thread!

        // Verify baseline counts
        let msgsBefore = try context.fetch(FetchDescriptor<MailMessage>())
        XCTAssertEqual(msgsBefore.count, 1)
        let attachBefore = try context.fetch(FetchDescriptor<MailAttachment>())
        XCTAssertEqual(attachBefore.count, 1)

        // Delete the thread and save
        context.delete(thread)
        try context.save()

        // MailMessage rows should be gone (cascade from MailThread → MailMessage)
        let msgsAfter = try context.fetch(FetchDescriptor<MailMessage>())
        XCTAssertEqual(msgsAfter.count, 0, "MailMessage rows should be cascade-deleted with the thread")

        // MailAttachment rows should be gone (cascade from MailMessage → MailAttachment)
        let attachAfter = try context.fetch(FetchDescriptor<MailAttachment>())
        XCTAssertEqual(attachAfter.count, 0, "MailAttachment rows should be cascade-deleted with the message")
    }
}
