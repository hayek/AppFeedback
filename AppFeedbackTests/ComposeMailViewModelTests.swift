import XCTest
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

    private func makeSettings() -> MailSettings {
        let s = MailSettings(defaults: UserDefaults(suiteName: "vm-\(UUID().uuidString)")!)
        s.credentials = SMTPCredentials(
            preset: .gmail, host: "smtp.gmail.com", port: 587,
            username: "alice@gmail.com", senderName: "Alice"
        )
        s.template = .empty
        return s
    }

    private func makeIssue() -> FeedbackIssue {
        FeedbackIssue(
            number: 7, title: "Crash", createdAt: Date(),
            rawBody: "", appName: "MyApp", appVersion: "1.0",
            device: "Mac", osVersion: "14.0", email: "bob@example.com",
            description: "Crash on launch"
        )
    }

    func test_send_callsSenderAndLogsSuccess() async throws {
        let sender = FakeSender()
        let log = ActivityLog(persistenceURL: nil)
        let vm = ComposeMailViewModel(
            recipient: "bob@example.com",
            issue: makeIssue(),
            repoOwner: "o", repoName: "r",
            settings: makeSettings(),
            sender: sender,
            activityLog: log,
            passwordLoader: { "test-secret" }
        )
        vm.subject = "Hello"
        vm.body = NSAttributedString(string: "Hi Bob")

        await vm.send()

        let sent = await sender.snapshot()
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent[0].0.recipients.first?.address, "bob@example.com")
        XCTAssertEqual(sent[0].0.subject, "Hello")
        XCTAssertEqual(sent[0].2, "test-secret")
        XCTAssertEqual(log.entries.first?.status, .success)
    }

    func test_send_failureLogsFailureWithDetail() async throws {
        let sender = FakeSender()
        await sender.setShouldThrow(NSError(domain: "Test", code: 1,
                                            userInfo: [NSLocalizedDescriptionKey: "boom"]))
        let log = ActivityLog(persistenceURL: nil)
        let vm = ComposeMailViewModel(
            recipient: "bob@example.com",
            issue: makeIssue(),
            repoOwner: "o", repoName: "r",
            settings: makeSettings(),
            sender: sender,
            activityLog: log,
            passwordLoader: { "test-secret" }
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
        let settings = MailSettings(defaults: UserDefaults(suiteName: "no-creds-\(UUID().uuidString)")!)
        let vm = ComposeMailViewModel(
            recipient: "bob@example.com",
            issue: makeIssue(),
            repoOwner: "o", repoName: "r",
            settings: settings,
            sender: sender,
            activityLog: log,
            passwordLoader: { "test-secret" }
        )
        vm.subject = "x"
        vm.body = NSAttributedString(string: "x")

        await vm.send()

        let sent = await sender.snapshot()
        XCTAssertTrue(sent.isEmpty)
        XCTAssertTrue(log.entries.isEmpty)
    }

    func test_send_withoutKeychainPassword_logsFailure() async throws {
        let sender = FakeSender()
        let log = ActivityLog(persistenceURL: nil)
        let vm = ComposeMailViewModel(
            recipient: "bob@example.com",
            issue: makeIssue(),
            repoOwner: "o", repoName: "r",
            settings: makeSettings(),
            sender: sender,
            activityLog: log,
            passwordLoader: { nil }
        )
        vm.subject = "x"
        vm.body = NSAttributedString(string: "x")

        await vm.send()

        let sent = await sender.snapshot()
        XCTAssertTrue(sent.isEmpty)
        XCTAssertEqual(log.entries.first?.status, .failure)
        XCTAssertEqual(log.entries.first?.detail, "No SMTP password configured.")
    }
}
#endif
