import XCTest
import SwiftData
@testable import AppFeedback

#if canImport(SwiftMail)
import SwiftMail

@MainActor
final class ComposeMailViewModelTests: XCTestCase {

    actor FakeSender: MailSending {
        var sent: [(SwiftMail.Email, SMTPCredentials, String)] = []
        var shouldThrow: Error?

        func send(_ email: SwiftMail.Email, using credentials: SMTPCredentials, password: String) async throws {
            if let shouldThrow { throw shouldThrow }
            sent.append((email, credentials, password))
        }
        func testConnection(_ credentials: SMTPCredentials, password: String) async throws {}
        func setShouldThrow(_ error: Error?) { shouldThrow = error }
        func snapshot() -> [(SwiftMail.Email, SMTPCredentials, String)] { sent }
    }

    private func makeStore(configured: Bool = true) throws -> MailAccountStore {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: MailAccount.self, configurations: config)
        let store = MailAccountStore(context: ModelContext(container))
        if configured {
            store.upsert { acc in
                acc.presetRaw = SMTPCredentials.Preset.gmail.rawValue
                acc.smtpHost = "smtp.gmail.com"
                acc.smtpPort = 587
                acc.smtpUsername = "alice@gmail.com"
                acc.senderName = "Alice"
            }
        }
        return store
    }

    private func makeIssue() -> FeedbackIssue {
        FeedbackIssue(
            number: 7, title: "Crash", createdAt: Date(),
            rawBody: "", appName: "MyApp", appVersion: "1.0",
            device: "Mac", osVersion: "14.0", email: "bob@example.com",
            description: "Crash on launch", labels: []
        )
    }

    func test_send_callsSenderAndLogsSuccess() async throws {
        let store = try makeStore()
        let acc = store.defaultSender
        XCTAssertNotNil(acc)
        let sender = FakeSender()
        let log = ActivityLog(persistenceURL: nil)
        let vm = ComposeMailViewModel(
            recipient: "bob@example.com",
            issue: makeIssue(),
            repoOwner: "o", repoName: "r",
            store: store,
            sender: sender,
            activityLog: log,
            senderAccountID: acc!.id,
            passwordLoader: { _ in "test-secret" }
        )
        vm.subject = "Hello"
        vm.body = NSAttributedString(string: "Hi Bob")

        await vm.send()

        let sent = await sender.snapshot()
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent[0].0.recipients.first?.address, "bob@example.com")
        XCTAssertEqual(sent[0].0.subject, "Hello")
        XCTAssertEqual(sent[0].2, "test-secret")
        XCTAssertNotNil(sent[0].0.messageID, "outbound mail must have a stamped Message-ID")
        XCTAssertEqual(log.entries.first?.status, .success)
    }

    func test_send_failureLogsFailureWithDetail() async throws {
        let store = try makeStore()
        let acc = store.defaultSender
        XCTAssertNotNil(acc)
        let sender = FakeSender()
        await sender.setShouldThrow(NSError(domain: "Test", code: 1,
                                            userInfo: [NSLocalizedDescriptionKey: "boom"]))
        let log = ActivityLog(persistenceURL: nil)
        let vm = ComposeMailViewModel(
            recipient: "bob@example.com",
            issue: makeIssue(),
            repoOwner: "o", repoName: "r",
            store: store,
            sender: sender,
            activityLog: log,
            senderAccountID: acc!.id,
            passwordLoader: { _ in "test-secret" }
        )
        vm.subject = "x"
        vm.body = NSAttributedString(string: "x")

        await vm.send()

        XCTAssertEqual(log.entries.first?.status, .failure)
        XCTAssertEqual(log.entries.first?.detail, "boom")
    }

    func test_send_withoutCredentials_doesNothing() async throws {
        let sender = FakeSender()
        let log = ActivityLog(persistenceURL: nil)
        let vm = ComposeMailViewModel(
            recipient: "bob@example.com",
            issue: makeIssue(),
            repoOwner: "o", repoName: "r",
            store: try makeStore(configured: false),
            sender: sender,
            activityLog: log,
            senderAccountID: UUID(),
            passwordLoader: { _ in "test-secret" }
        )
        vm.subject = "x"
        vm.body = NSAttributedString(string: "x")

        await vm.send()

        let sent = await sender.snapshot()
        XCTAssertTrue(sent.isEmpty)
        XCTAssertTrue(log.entries.isEmpty)
    }

    func test_send_withoutKeychainPassword_logsFailure() async throws {
        let store = try makeStore()
        let acc = store.defaultSender
        XCTAssertNotNil(acc)
        let sender = FakeSender()
        let log = ActivityLog(persistenceURL: nil)
        let vm = ComposeMailViewModel(
            recipient: "bob@example.com",
            issue: makeIssue(),
            repoOwner: "o", repoName: "r",
            store: store,
            sender: sender,
            activityLog: log,
            senderAccountID: acc!.id,
            passwordLoader: { _ in nil }
        )
        vm.subject = "x"
        vm.body = NSAttributedString(string: "x")

        await vm.send()

        let sent = await sender.snapshot()
        XCTAssertTrue(sent.isEmpty)
        XCTAssertEqual(log.entries.first?.status, .failure)
        XCTAssertEqual(log.entries.first?.detail, "No SMTP password configured.")
    }

    func test_send_withInReplyTo_writesReplyHeaders() async throws {
        let store = try makeStore()
        let acc = store.defaultSender
        XCTAssertNotNil(acc)
        let sender = FakeSender()
        let log = ActivityLog(persistenceURL: nil)
        let parent = MailMessageHeaders(
            messageID: "<parent@x>",
            inReplyTo: nil,
            references: ["<root@x>"]
        )
        let vm = ComposeMailViewModel(
            recipient: "bob@example.com",
            issue: makeIssue(),
            repoOwner: "o", repoName: "r",
            store: store,
            sender: sender,
            activityLog: log,
            inReplyTo: parent,
            senderAccountID: acc!.id,
            passwordLoader: { _ in "pw" }
        )
        vm.subject = "Re: Crash"
        vm.body = NSAttributedString(string: "ack")

        await vm.send()

        let sent = await sender.snapshot()
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent[0].0.additionalHeaders?["In-Reply-To"], "<parent@x>")
        XCTAssertEqual(sent[0].0.additionalHeaders?["References"], "<root@x> <parent@x>")
    }

    func test_sendUsesCredentialsAndPasswordForRequestedAccount() async throws {
        let store = try makeStore(configured: false)
        let a = store.add { acc in
            acc.smtpUsername = "alice@x"
            acc.senderName = "Alice"
            acc.smtpHost = "smtp.x"
            acc.smtpPort = 587
        }
        let b = store.add { acc in
            acc.smtpUsername = "bob@x"
            acc.senderName = "Bob"
            acc.smtpHost = "smtp.x"
            acc.smtpPort = 587
        }

        let sender = FakeSender()
        let log = ActivityLog(persistenceURL: nil)

        let vm = ComposeMailViewModel(
            recipient: "user@example.com",
            issue: makeIssue(),
            repoOwner: "o", repoName: "r",
            store: store,
            sender: sender,
            activityLog: log,
            senderAccountID: b.id,
            passwordLoader: { @Sendable id in
                XCTAssertEqual(id, b.id)
                return "bob-password"
            }
        )
        vm.subject = "Test"
        vm.body = NSAttributedString(string: "hello")
        await vm.send()

        let sent = await sender.snapshot()
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent[0].1.username, "bob@x")
        XCTAssertEqual(sent[0].2, "bob-password")
        _ = a
    }
}
#endif
