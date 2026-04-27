import XCTest
@testable import AppFeedback

#if canImport(SwiftMail)
import SwiftMail
#endif

#if os(macOS)
import AppKit
#endif

#if canImport(SwiftMail)
final class MailComposerTests: XCTestCase {

    private func makeContext(issueTitle: String? = "Bug: crash on launch",
                             issueURL: URL? = URL(string: "https://github.com/o/r/issues/42"))
    -> PlaceholderContext {
        PlaceholderContext(
            sender: SMTPCredentials(
                preset: .gmail, host: "smtp.gmail.com", port: 587,
                username: "alice@gmail.com", senderName: "Alice Example"
            ),
            recipient: "bob@example.com",
            appName: "MyApp",
            issueTitle: issueTitle,
            issueURL: issueURL,
            date: ISO8601DateFormatter().date(from: "2026-04-27T10:00:00Z")!
        )
    }

    private func makeDraft(text: String, subject: String = "Hello") -> DraftMessage {
        DraftMessage(
            recipient: "bob@example.com",
            subject: subject,
            body: NSAttributedString(string: text)
        )
    }

    func test_substitutesAllPlaceholders() {
        let template = MailTemplate(
            headerHTML: "<p>To {{recipient_email}} from {{sender_name}} ({{sender_email}}) on {{date}}</p>",
            footerHTML: "<p>App: {{app_name}} - Issue: {{issue_title}} - {{issue_url}}</p>"
        )
        let composer = MailComposer()
        let email = composer.compose(
            draft: makeDraft(text: "body"),
            context: makeContext(),
            template: template
        )

        XCTAssertTrue(email.htmlBody?.contains("To bob@example.com from Alice Example (alice@gmail.com)") == true)
        XCTAssertTrue(email.htmlBody?.contains("App: MyApp") == true)
        XCTAssertTrue(email.htmlBody?.contains("Issue: Bug: crash on launch") == true)
        XCTAssertTrue(email.htmlBody?.contains("https://github.com/o/r/issues/42") == true)
    }

    func test_missingIssueContext_substitutesEmpty() {
        let template = MailTemplate(
            headerHTML: "<p>{{issue_title}}|{{issue_url}}</p>",
            footerHTML: ""
        )
        let composer = MailComposer()
        let email = composer.compose(
            draft: makeDraft(text: "body"),
            context: makeContext(issueTitle: nil, issueURL: nil),
            template: template
        )
        XCTAssertTrue(email.htmlBody?.contains("|") == true)
        XCTAssertFalse(email.htmlBody?.contains("{{") == true)
    }

    func test_repeatedPlaceholdersAllSubstitute() {
        let template = MailTemplate(
            headerHTML: "<p>{{app_name}} {{app_name}} {{app_name}}</p>",
            footerHTML: ""
        )
        let composer = MailComposer()
        let email = composer.compose(
            draft: makeDraft(text: "body"),
            context: makeContext(),
            template: template
        )
        let count = email.htmlBody?.components(separatedBy: "MyApp").count ?? 0
        XCTAssertEqual(count - 1, 3)
    }

    func test_emailHasBothTextAndHTMLBodies() {
        let composer = MailComposer()
        let email = composer.compose(
            draft: makeDraft(text: "body content"),
            context: makeContext(),
            template: MailTemplate(headerHTML: "<p>HEADER</p>", footerHTML: "<p>FOOTER</p>")
        )
        XCTAssertNotNil(email.htmlBody)
        XCTAssertTrue(email.textBody.contains("body content"))
        XCTAssertTrue(email.textBody.contains("HEADER"))
        XCTAssertTrue(email.textBody.contains("FOOTER"))
    }

    func test_subjectPropagatesToEmail() {
        let composer = MailComposer()
        let email = composer.compose(
            draft: makeDraft(text: "x", subject: "My Subject"),
            context: makeContext(),
            template: .empty
        )
        XCTAssertEqual(email.subject, "My Subject")
    }

    func test_senderUsesSenderNameAndUsername() {
        let composer = MailComposer()
        let email = composer.compose(
            draft: makeDraft(text: "x"),
            context: makeContext(),
            template: .empty
        )
        XCTAssertEqual(email.sender.address, "alice@gmail.com")
        XCTAssertEqual(email.sender.name, "Alice Example")
    }

    func test_composer_sanitizesHeaderHTML() {
        let template = MailTemplate(
            headerHTML: "<p>OK</p><script>alert(1)</script>",
            footerHTML: ""
        )
        let composer = MailComposer()
        let email = composer.compose(
            draft: makeDraft(text: "body"),
            context: makeContext(),
            template: template
        )
        XCTAssertFalse(email.htmlBody?.contains("<script") ?? true)
        XCTAssertFalse(email.htmlBody?.contains("alert(") ?? true)
        XCTAssertTrue(email.htmlBody?.contains("<p>OK</p>") ?? false)
    }
}
#endif
