import XCTest
@testable import AppFeedback
#if canImport(SwiftMail)
import SwiftMail
#endif

final class MailComposerAttachmentsTests: XCTestCase {

    func test_compose_includes_attachments_when_provided() {
        let composer = MailComposer()
        let draft = DraftMessage(
            recipient: "u@example.com",
            subject: "Re",
            body: NSAttributedString(string: "Hi")
        )
        let context = PlaceholderContext(
            sender: SMTPCredentials(
                preset: .gmail,
                host: "smtp.gmail.com",
                port: 587,
                username: "me@example.com",
                senderName: "Me"
            ),
            recipient: "u@example.com",
            appName: "App",
            issueTitle: nil,
            issueURL: nil,
            feedbackBody: nil,
            date: Date()
        )
        let template = MailTemplate(headerHTML: "", footerHTML: "")
        let pending = [
            PendingAttachment(filename: "shot.png", mimeType: "image/png", data: Data([1, 2, 3])),
            PendingAttachment(filename: "log.txt", mimeType: "text/plain", data: Data("log".utf8)),
        ]
        let email = composer.compose(
            draft: draft,
            context: context,
            template: template,
            attachments: pending
        )
        XCTAssertEqual(email.attachments?.count, 2)
        XCTAssertEqual(email.attachments?[0].filename, "shot.png")
        XCTAssertEqual(email.attachments?[0].mimeType, "image/png")
    }

    func test_compose_omits_attachments_when_none_provided() {
        let composer = MailComposer()
        let draft = DraftMessage(
            recipient: "u@example.com",
            subject: "Re",
            body: NSAttributedString(string: "Hi")
        )
        let context = PlaceholderContext(
            sender: SMTPCredentials(
                preset: .gmail,
                host: "smtp.gmail.com",
                port: 587,
                username: "me@example.com",
                senderName: "Me"
            ),
            recipient: "u@example.com",
            appName: "App",
            issueTitle: nil,
            issueURL: nil,
            feedbackBody: nil,
            date: Date()
        )
        let template = MailTemplate(headerHTML: "", footerHTML: "")
        let email = composer.compose(
            draft: draft,
            context: context,
            template: template
        )
        XCTAssertNil(email.attachments)
    }
}
