import XCTest
import SwiftData
@testable import AppFeedback

@MainActor
final class FeedbackClipboardTests: XCTestCase {

    // MARK: - Helpers

    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(
            for: MailThread.self, MailMessage.self, MailAttachment.self,
                MailAttachmentLocal.self, MailAccountLocalState.self,
            configurations: config
        )
        return ModelContext(container)
    }

    private func makeIssue(
        title: String = "App crashes",
        body: String = "It crashes on launch",
        appName: String? = "MyApp",
        appVersion: String? = "1.2",
        email: String? = "user@example.com",
        labels: [IssueLabel] = []
    ) -> FeedbackIssue {
        FeedbackIssue(
            number: 7,
            title: title,
            createdAt: Date(timeIntervalSince1970: 0),
            rawBody: body,
            appName: appName,
            appVersion: appVersion,
            device: nil,
            osVersion: nil,
            email: email,
            description: body,
            labels: labels
        )
    }

    private func makeMessage(
        id: String,
        from: String,
        name: String? = nil,
        date: Date,
        body: String,
        direction: MailMessage.Direction = .inbound
    ) -> MailMessage {
        let m = MailMessage(
            messageID: id,
            fromAddress: from,
            fromName: name,
            date: date,
            bodyPlain: body
        )
        m.direction = direction
        return m
    }

    private func makeThread(_ messages: [MailMessage], in ctx: ModelContext) throws -> MailThread {
        let thread = MailThread(
            subject: "Re: App crashes",
            issueRepoOwner: "owner",
            issueRepoName: "repo",
            issueNumber: 7
        )
        ctx.insert(thread)
        for m in messages {
            m.thread = thread
            ctx.insert(m)
        }
        try ctx.save()
        return thread
    }

    // MARK: - Issue-only behaviour is preserved

    func test_noThreads_matchesIssueOnlyFormat() {
        let issue = makeIssue()
        let text = FeedbackClipboard.text(for: issue, threads: [], translated: false)

        let expected = """
        App crashes

        It crashes on launch

        MyApp • v1.2 • ✉ user@example.com
        """
        XCTAssertEqual(text, expected)
    }

    func test_noThreads_hasNoRepliesSection() {
        let issue = makeIssue()
        let text = FeedbackClipboard.text(for: issue, threads: [], translated: false)
        XCTAssertFalse(text.contains("Replies"), "Issue without threads must not emit a Replies section")
    }

    // MARK: - Replies are appended

    func test_singleInboundReply_includesSenderAndBody() throws {
        let ctx = try makeContext()
        let reply = makeMessage(
            id: "<r1@example.com>",
            from: "jane@example.com",
            name: "Jane Doe",
            date: Date(timeIntervalSince1970: 1000),
            body: "Thanks for the report, we are on it."
        )
        let thread = try makeThread([reply], in: ctx)

        let text = FeedbackClipboard.text(for: makeIssue(), threads: [thread], translated: false)

        XCTAssertTrue(text.contains("Replies"), "Expected a Replies section header")
        XCTAssertTrue(text.contains("Jane Doe (jane@example.com)"), "Expected sender name + address line")
        XCTAssertTrue(text.contains("Thanks for the report, we are on it."), "Expected reply body")
        // The issue body still comes first.
        let issueIdx = try XCTUnwrap(text.range(of: "It crashes on launch"))
        let replyIdx = try XCTUnwrap(text.range(of: "Thanks for the report"))
        XCTAssertTrue(issueIdx.lowerBound < replyIdx.lowerBound, "Issue body must precede replies")
    }

    func test_senderWithoutName_usesBareAddress() throws {
        let ctx = try makeContext()
        let reply = makeMessage(
            id: "<r1@example.com>",
            from: "bob@example.com",
            name: nil,
            date: Date(timeIntervalSince1970: 1000),
            body: "Bare sender reply."
        )
        let thread = try makeThread([reply], in: ctx)

        let text = FeedbackClipboard.text(for: makeIssue(), threads: [thread], translated: false)
        XCTAssertTrue(text.contains("bob@example.com"))
        XCTAssertFalse(text.contains("()"), "Empty name must not produce dangling parentheses")
    }

    func test_quotedReplyTail_isStripped() throws {
        let ctx = try makeContext()
        let body = """
        Here is my actual reply.

        On Tue, Jun 3, 2026 at 2:00 PM, Support wrote:
        > Please tell us more about the crash.
        > Thanks!
        """
        let reply = makeMessage(
            id: "<r1@example.com>",
            from: "jane@example.com",
            date: Date(timeIntervalSince1970: 1000),
            body: body
        )
        let thread = try makeThread([reply], in: ctx)

        let text = FeedbackClipboard.text(for: makeIssue(), threads: [thread], translated: false)
        XCTAssertTrue(text.contains("Here is my actual reply."))
        XCTAssertFalse(text.contains("Please tell us more about the crash."),
                       "Quoted-reply tail should be stripped from the copied transcript")
    }

    func test_multipleMessages_chronologicalOrder() throws {
        let ctx = try makeContext()
        // Insert out of order; later date should still come last.
        let second = makeMessage(
            id: "<r2@example.com>",
            from: "support@example.com",
            date: Date(timeIntervalSince1970: 5000),
            body: "SECOND message in time.",
            direction: .outbound
        )
        let first = makeMessage(
            id: "<r1@example.com>",
            from: "jane@example.com",
            date: Date(timeIntervalSince1970: 1000),
            body: "FIRST message in time."
        )
        let thread = try makeThread([second, first], in: ctx)

        let text = FeedbackClipboard.text(for: makeIssue(), threads: [thread], translated: false)
        let firstIdx = try XCTUnwrap(text.range(of: "FIRST message in time."))
        let secondIdx = try XCTUnwrap(text.range(of: "SECOND message in time."))
        XCTAssertTrue(firstIdx.lowerBound < secondIdx.lowerBound,
                      "Messages must appear in chronological order")
    }

    func test_emptyBodyReply_showsPlaceholderNotDanglingHeader() throws {
        let ctx = try makeContext()
        let reply = makeMessage(
            id: "<att@example.com>",
            from: "jane@example.com",
            name: "Jane Doe",
            date: Date(timeIntervalSince1970: 1000),
            body: ""   // e.g. an attachment-only reply
        )
        let thread = try makeThread([reply], in: ctx)

        let text = FeedbackClipboard.text(for: makeIssue(), threads: [thread], translated: false)
        XCTAssertTrue(text.contains("Jane Doe (jane@example.com)"), "Empty-body reply must still be represented")
        XCTAssertTrue(text.contains("(no text)"), "Empty body should render a placeholder, not a dangling header")
        XCTAssertFalse(text.contains("\n\n\n"), "Must not leave a blank gap where the body would be")
    }

    func test_allQuotedReply_showsPlaceholderAndStripsQuote() throws {
        let ctx = try makeContext()
        let body = """
        On Tue, Jun 3, 2026 at 2:00 PM, Support wrote:
        > How can we help?
        """
        let reply = makeMessage(
            id: "<q@example.com>",
            from: "jane@example.com",
            date: Date(timeIntervalSince1970: 1000),
            body: body
        )
        let thread = try makeThread([reply], in: ctx)

        let text = FeedbackClipboard.text(for: makeIssue(), threads: [thread], translated: false)
        XCTAssertFalse(text.contains("How can we help?"), "Quoted-only body should be stripped to empty")
        XCTAssertTrue(text.contains("(no text)"), "A reply with no new text should render a placeholder")
    }

    func test_multipleThreads_dedupedAndChronologicalAcrossThreads() throws {
        let ctx = try makeContext()
        let threadA = try makeThread([
            makeMessage(id: "<a@x>", from: "jane@example.com",
                        date: Date(timeIntervalSince1970: 1000), body: "ALPHA from A")
        ], in: ctx)
        let threadB = try makeThread([
            makeMessage(id: "<a@x>", from: "jane@example.com",
                        date: Date(timeIntervalSince1970: 1000), body: "ALPHA from A"), // cross-thread dup
            makeMessage(id: "<b@x>", from: "support@example.com",
                        date: Date(timeIntervalSince1970: 2000), body: "BETA from B", direction: .outbound)
        ], in: ctx)

        let text = FeedbackClipboard.text(for: makeIssue(), threads: [threadA, threadB], translated: false)
        let alphaCount = text.components(separatedBy: "ALPHA from A").count - 1
        XCTAssertEqual(alphaCount, 1, "Duplicate messageID across threads must collapse to one entry")
        let alphaIdx = try XCTUnwrap(text.range(of: "ALPHA from A"))
        let betaIdx = try XCTUnwrap(text.range(of: "BETA from B"))
        XCTAssertTrue(alphaIdx.lowerBound < betaIdx.lowerBound, "Messages from all threads sort chronologically")
        XCTAssertTrue(text.contains("Replies (2):"), "Count reflects deduped messages across threads")
    }

    func test_issueWithEmptyBody_repliesStillAppendedCleanly() throws {
        let ctx = try makeContext()
        let thread = try makeThread([
            makeMessage(id: "<r@x>", from: "jane@example.com",
                        date: Date(timeIntervalSince1970: 1000), body: "A reply with no issue body above it.")
        ], in: ctx)

        let issue = makeIssue(body: "")
        let text = FeedbackClipboard.text(for: issue, threads: [thread], translated: false)
        XCTAssertTrue(text.hasPrefix("App crashes"), "Title still leads")
        XCTAssertTrue(text.contains("Replies (1):"))
        XCTAssertTrue(text.contains("A reply with no issue body above it."))
        XCTAssertFalse(text.contains("\n\n\n"), "No blank-gap artifact from the missing body")
    }

    func test_repliesHeader_usesExactMessageCount() throws {
        let ctx = try makeContext()
        let oneThread = try makeThread([
            makeMessage(id: "<r1@x>", from: "a@x",
                        date: Date(timeIntervalSince1970: 1000), body: "one")
        ], in: ctx)
        let single = FeedbackClipboard.text(for: makeIssue(), threads: [oneThread], translated: false)
        XCTAssertTrue(single.contains("Replies (1):"), "Single reply renders exact 'Replies (1):' header")

        let threeThread = try makeThread([
            makeMessage(id: "<m1@x>", from: "a@x", date: Date(timeIntervalSince1970: 1000), body: "one"),
            makeMessage(id: "<m2@x>", from: "b@x", date: Date(timeIntervalSince1970: 2000), body: "two"),
            makeMessage(id: "<m3@x>", from: "c@x", date: Date(timeIntervalSince1970: 3000), body: "three")
        ], in: ctx)
        let three = FeedbackClipboard.text(for: makeIssue(), threads: [threeThread], translated: false)
        XCTAssertTrue(three.contains("Replies (3):"), "Three replies render exact 'Replies (3):' header")
    }

    func test_duplicateMessageID_collapsedOnce() throws {
        let ctx = try makeContext()
        let a = makeMessage(
            id: "<dup@example.com>",
            from: "jane@example.com",
            date: Date(timeIntervalSince1970: 1000),
            body: "UNIQUEBODY duplicate text."
        )
        let b = makeMessage(
            id: "<dup@example.com>",
            from: "jane@example.com",
            date: Date(timeIntervalSince1970: 1000),
            body: "UNIQUEBODY duplicate text."
        )
        let thread = try makeThread([a, b], in: ctx)

        let text = FeedbackClipboard.text(for: makeIssue(), threads: [thread], translated: false)
        let occurrences = text.components(separatedBy: "UNIQUEBODY duplicate text.").count - 1
        XCTAssertEqual(occurrences, 1, "Duplicate messageID rows must be collapsed to a single entry")
    }
}
