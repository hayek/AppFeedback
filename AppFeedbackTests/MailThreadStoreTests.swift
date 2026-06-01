import XCTest
import SwiftData
import CoreData
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

        let result = store.threads(forIssue: (owner: "org", repo: "repo", number: 10, title: ""))
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

    // MARK: - Test 14: NSPersistentStoreRemoteChange bumps version

    /// Regression: replies sent on another device (synced via CloudKit) used to stay invisible
    /// on this device until app relaunch because `version` only ticked on local writes.
    /// `MailThreadStore` now listens for `.NSPersistentStoreRemoteChange` so SwiftUI observers
    /// re-fetch when CloudKit merges rows into the local store.
    func test_remoteStoreChange_bumpsVersion() async throws {
        let context = try makeContext()
        let store = MailThreadStore(context: context)
        let baseline = store.version

        // Give the listener Task a chance to start its `for await` loop and register the
        // underlying notification observer — otherwise the notification we post below would
        // fire before the observer exists and be missed.
        try await Task.sleep(for: .milliseconds(50))

        // Post repeatedly with yields so we don't depend on a single observer-registration
        // timing window. The store coalesces multiple posts into multiple version ticks,
        // so as long as one is observed the test passes.
        for _ in 0..<5 {
            NotificationCenter.default.post(
                name: .NSPersistentStoreRemoteChange,
                object: nil
            )
            try await Task.sleep(for: .milliseconds(20))
        }

        XCTAssertGreaterThan(store.version, baseline,
            "Remote store change should bump version so observers re-fetch")
    }

    // MARK: - Sent enrichment: upgradeOutbound + outboundNeedingEnrichment

    private func fetchMessage(_ context: ModelContext, _ messageID: String) throws -> MailMessage? {
        try context.fetch(FetchDescriptor<MailMessage>(
            predicate: #Predicate { $0.messageID == messageID }
        )).first
    }

    @discardableResult
    private func recordAppOutbound(
        _ store: MailThreadStore,
        _ messageID: String,
        sentAt: Date? = Date(),
        date: Date = Date(),
        accountID: UUID? = nil
    ) -> MailMessage {
        let m = store.recordOutbound(
            messageID: messageID,
            repoOwner: "o", repoName: "r", issueNumber: 7,
            from: "me@example.com", fromName: "Me",
            to: ["user@example.com"], cc: [],
            subject: "Re: thing", bodyPlain: "see image", bodyHTML: nil,
            date: date,
            accountID: accountID,
            replyHeaders: nil
        )
        m.sentAt = sentAt   // recordOutbound leaves this nil; the real send sets it on success
        return m
    }

    func test_upgradeOutbound_stampsIdentityAndInsertsAttachments() throws {
        let context = try makeContext()
        let store = MailThreadStore(context: context)
        let mid = "<af~o~r~7~abc@app-feedback.local>"
        recordAppOutbound(store, mid)

        let metas = [
            ParsedAttachmentMeta(partID: "2", filename: "shot.png", mimeType: "image/png", sizeBytes: 1024, contentID: "<cid@x>"),
            ParsedAttachmentMeta(partID: "3", filename: "doc.pdf", mimeType: "application/pdf", sizeBytes: 2048)
        ]
        let changed = store.upgradeOutbound(messageID: mid, uid: 42, folder: "[Gmail]/Sent Mail", attachments: metas, accountID: nil)
        XCTAssertTrue(changed)

        let msg = try XCTUnwrap(fetchMessage(context, mid))
        XCTAssertEqual(msg.uid, 42)
        XCTAssertEqual(msg.folder, "[Gmail]/Sent Mail")
        XCTAssertEqual((msg.attachments ?? []).count, 2)
        let png = try XCTUnwrap((msg.attachments ?? []).first { $0.partID == "2" })
        XCTAssertTrue(png.isInlineImage, "image with a contentID should render as an inline thumbnail")
    }

    func test_upgradeOutbound_idempotentReCall_insertsNothing_noVersionBump() throws {
        let context = try makeContext()
        let store = MailThreadStore(context: context)
        let mid = "<af~o~r~7~abc@app-feedback.local>"
        recordAppOutbound(store, mid)
        let metas = [ParsedAttachmentMeta(partID: "2", filename: "shot.png", mimeType: "image/png", sizeBytes: 1024, contentID: "<cid@x>")]

        XCTAssertTrue(store.upgradeOutbound(messageID: mid, uid: 42, folder: "Sent", attachments: metas, accountID: nil))
        let versionAfterFirst = store.version

        let changedAgain = store.upgradeOutbound(messageID: mid, uid: 42, folder: "Sent", attachments: metas, accountID: nil)
        XCTAssertFalse(changedAgain, "Re-enriching with the same data must be a no-op")
        XCTAssertEqual(store.version, versionAfterFirst, "A no-op upgrade must not bump version / push to CloudKit")
        XCTAssertEqual((try fetchMessage(context, mid)?.attachments ?? []).count, 1, "Must not duplicate the attachment row")
    }

    func test_upgradeOutbound_neverDowngradesStampedIdentity() throws {
        let context = try makeContext()
        let store = MailThreadStore(context: context)
        let mid = "<af~o~r~7~abc@app-feedback.local>"
        recordAppOutbound(store, mid)
        _ = store.upgradeOutbound(messageID: mid, uid: 42, folder: "Sent", attachments: [], accountID: nil)

        // A later call with no server identity must not wipe the stamped uid/folder.
        _ = store.upgradeOutbound(messageID: mid, uid: 0, folder: "", attachments: [], accountID: nil)
        let msg = try XCTUnwrap(fetchMessage(context, mid))
        XCTAssertEqual(msg.uid, 42)
        XCTAssertEqual(msg.folder, "Sent")
    }

    func test_upgradeOutbound_returnsFalseForInboundAndUnknown() throws {
        let context = try makeContext()
        let store = MailThreadStore(context: context)
        // Unknown messageID
        XCTAssertFalse(store.upgradeOutbound(messageID: "<nope@x>", uid: 1, folder: "Sent", attachments: [], accountID: nil))
        // Inbound message must never be treated as outbound
        _ = store.recordInbound(message: makeParsed(messageID: "<in@example.com>"))
        XCTAssertFalse(store.upgradeOutbound(messageID: "<in@example.com>", uid: 1, folder: "Sent", attachments: [], accountID: nil))
    }

    func test_outboundNeedingEnrichment_returnsOnlyUnstampedSentRecentAppOutbound() throws {
        let context = try makeContext()
        let store = MailThreadStore(context: context)
        let since = Date().addingTimeInterval(-3600)   // 1-hour window
        let acct = UUID()
        let otherAcct = UUID()

        let unstamped = "<af~o~r~7~unstamped@app-feedback.local>"
        let stamped = "<af~o~r~7~stamped@app-feedback.local>"
        let foreign = "<someone@gmail.com>"                          // not app-composed
        let failed = "<af~o~r~7~failed@app-feedback.local>"          // never sent
        let aged = "<af~o~r~7~aged@app-feedback.local>"              // older than the window
        let otherAccount = "<af~o~r~7~other@app-feedback.local>"     // a different account's reply
        recordAppOutbound(store, unstamped, accountID: acct)
        recordAppOutbound(store, stamped, accountID: acct)
        recordAppOutbound(store, foreign, accountID: acct)
        recordAppOutbound(store, failed, sentAt: nil, accountID: acct)
        recordAppOutbound(store, aged, date: Date().addingTimeInterval(-7200), accountID: acct)
        recordAppOutbound(store, otherAccount, accountID: otherAcct)
        _ = store.upgradeOutbound(messageID: stamped, uid: 5, folder: "Sent", attachments: [], accountID: acct)

        let needing = store.outboundNeedingEnrichment(since: since, accountID: acct)
        XCTAssertTrue(needing.contains(unstamped), "sent, recent, unstamped app reply needs enrichment")
        XCTAssertFalse(needing.contains(stamped), "already-stamped (uid>0) reply must drop out")
        XCTAssertFalse(needing.contains(foreign), "non-app-domain message must be ignored")
        XCTAssertFalse(needing.contains(failed), "a never-sent (sentAt==nil) row has no Sent copy — must be excluded")
        XCTAssertFalse(needing.contains(aged), "a reply older than the window must stop forcing a Sent scan")
        XCTAssertFalse(needing.contains(otherAccount), "another account's reply must not appear in this account's gate")
    }

    func test_dedupedAttachments_collapsesDuplicatePartIDs() throws {
        let context = try makeContext()
        let msg = MailMessage(messageID: "<x@app-feedback.local>", directionRaw: MailMessage.Direction.outbound.rawValue)
        context.insert(msg)
        // Simulate a CloudKit cross-device duplicate: two rows, same partID.
        context.insert(MailAttachment(messageID: msg.messageID, partID: "2", filename: "a.png", mimeType: "image/png", sizeBytes: 1, message: msg))
        context.insert(MailAttachment(messageID: msg.messageID, partID: "2", filename: "a.png", mimeType: "image/png", sizeBytes: 1, message: msg))
        XCTAssertEqual((msg.attachments ?? []).count, 2)
        XCTAssertEqual(msg.dedupedAttachments.count, 1, "duplicate partIDs collapse at read time")
    }

    func test_markSent_persistsSentAtAndBumpsVersion() throws {
        let context = try makeContext()
        let store = MailThreadStore(context: context)
        let mid = "<af~o~r~7~marksent@app-feedback.local>"
        _ = store.recordOutbound(
            messageID: mid, repoOwner: "o", repoName: "r", issueNumber: 7,
            from: "me@example.com", fromName: "Me", to: ["user@example.com"], cc: [],
            subject: "Re: thing", bodyPlain: "x", bodyHTML: nil, date: Date(), replyHeaders: nil
        )
        XCTAssertNil(try fetchMessage(context, mid)?.sentAt, "recordOutbound leaves sentAt nil")
        let v = store.version

        store.markSent(messageID: mid)
        XCTAssertNotNil(try fetchMessage(context, mid)?.sentAt, "markSent must persist sentAt (commitChange → save)")
        XCTAssertGreaterThan(store.version, v, "markSent must bump version so the Sent badge updates")

        // Idempotent: re-marking leaves the timestamp and version untouched.
        let firstSentAt = try XCTUnwrap(fetchMessage(context, mid)?.sentAt)
        let v2 = store.version
        store.markSent(messageID: mid)
        XCTAssertEqual(try fetchMessage(context, mid)?.sentAt, firstSentAt, "re-marking must not move the timestamp")
        XCTAssertEqual(store.version, v2, "idempotent markSent must not bump version")
    }

    func test_withBatch_noOpDoesNotBumpVersion() throws {
        let context = try makeContext()
        let store = MailThreadStore(context: context)
        let v = store.version
        // A batch whose body requests no commit (e.g. a Sent-enrichment poll whose replies aren't
        // filed in Sent yet) must not save / bump version / drop caches — otherwise every poll
        // forces redundant UI re-fetches while a reply awaits its Sent copy.
        store.withBatch {
            _ = store.upgradeOutbound(messageID: "<absent@app-feedback.local>", uid: 9, folder: "Sent", attachments: [], accountID: nil)
        }
        XCTAssertEqual(store.version, v, "A no-op batch must not bump version")

        // A productive batch bumps exactly once.
        let mid = "<af~o~r~7~prod@app-feedback.local>"
        recordAppOutbound(store, mid)
        let v2 = store.version
        store.withBatch {
            _ = store.upgradeOutbound(messageID: mid, uid: 7, folder: "Sent", attachments: [
                ParsedAttachmentMeta(partID: "2", filename: "s.png", mimeType: "image/png", sizeBytes: 1)
            ], accountID: nil)
        }
        XCTAssertEqual(store.version, v2 + 1, "A batch that changes a row must bump version exactly once")
    }
}
