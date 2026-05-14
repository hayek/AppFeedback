import XCTest
@testable import AppFeedback

@MainActor
final class MailDraftStoreTests: XCTestCase {
    private let threadA = UUID()
    private let threadB = UUID()

    func test_draft_returnsNilForUnknownKey() {
        let store = MailDraftStore()
        XCTAssertNil(store.draft(for: .reply(threadID: threadA)))
    }

    func test_setSubjectAndBody_persistsThenReads() {
        let store = MailDraftStore()
        let key = DraftKey.reply(threadID: threadA)
        store.setSubject("Re: Crash", for: key)
        store.setBody("Hi Bob", for: key)

        let draft = store.draft(for: key)
        XCTAssertEqual(draft?.subject, "Re: Crash")
        XCTAssertEqual(draft?.body, "Hi Bob")
    }

    func test_setSubject_createsDraftEvenWithoutBody() {
        let store = MailDraftStore()
        let key = DraftKey.reply(threadID: threadA)
        store.setSubject("Subject only", for: key)

        let draft = store.draft(for: key)
        XCTAssertEqual(draft?.subject, "Subject only")
        XCTAssertEqual(draft?.body, "")
    }

    func test_clear_removesDraft() {
        let store = MailDraftStore()
        let key = DraftKey.reply(threadID: threadA)
        store.setBody("typed", for: key)
        store.clear(key)
        XCTAssertNil(store.draft(for: key))
    }

    func test_keys_areIsolated() {
        let store = MailDraftStore()
        let keyA = DraftKey.reply(threadID: threadA)
        let keyB = DraftKey.reply(threadID: threadB)
        store.setBody("A", for: keyA)
        store.setBody("B", for: keyB)

        XCTAssertEqual(store.draft(for: keyA)?.body, "A")
        XCTAssertEqual(store.draft(for: keyB)?.body, "B")
    }

    func test_newEmailKey_isDistinctFromReplyKey() {
        let store = MailDraftStore()
        let replyKey = DraftKey.reply(threadID: threadA)
        let newKey = DraftKey.newEmail(repoOwner: "o", repoName: "r", issueNumber: 1, recipient: "x@y.com")
        store.setBody("reply", for: replyKey)
        store.setBody("new", for: newKey)

        XCTAssertEqual(store.draft(for: replyKey)?.body, "reply")
        XCTAssertEqual(store.draft(for: newKey)?.body, "new")
    }

    func test_openRequest_returnsNilForUnknownKey() {
        let store = MailDraftStore()
        XCTAssertNil(store.openRequest(for: .reply(threadID: threadA)))
    }

    func test_setOpenRequest_persistsAndClears() {
        let store = MailDraftStore()
        let key = DraftKey.reply(threadID: threadA)
        let issue = FeedbackIssue(
            number: 7, title: "Crash", createdAt: Date(),
            rawBody: "", appName: "MyApp", appVersion: "1.0",
            device: "Mac", osVersion: "14.0", email: "bob@example.com",
            description: "Crash on launch", labels: []
        )
        let request = ComposeRequest(
            recipient: "bob@example.com",
            issue: issue,
            repoOwner: "o",
            repoName: "r",
            inReplyTo: nil,
            subjectOverride: nil,
            senderAccountID: nil
        )

        store.setOpenRequest(request, for: key)
        XCTAssertEqual(store.openRequest(for: key)?.recipient, "bob@example.com")
        XCTAssertEqual(store.openRequest(for: key)?.issue.number, 7)

        store.clearOpenRequest(for: key)
        XCTAssertNil(store.openRequest(for: key))
    }
}
