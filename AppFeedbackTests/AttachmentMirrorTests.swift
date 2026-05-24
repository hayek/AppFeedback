// AppFeedbackTests/AttachmentMirrorTests.swift
import XCTest
@testable import AppFeedback

final class AttachmentMirrorTests: XCTestCase {

    private func context(with attachments: [FeedbackAttachmentRef]) -> PlaceholderContext {
        PlaceholderContext(
            sender: SMTPCredentials(preset: .gmail, host: "h", port: 1, username: "a@b", senderName: "A"),
            recipient: "u@example.com",
            appName: "App",
            issueTitle: "T",
            issueURL: URL(string: "https://example.com")!,
            feedbackBody: "Body",
            feedbackAttachments: attachments,
            date: Date()
        )
    }

    func test_placeholder_empty_when_no_attachments() {
        let composer = MailComposer()
        let out = composer.applyPlaceholders("Att: {{feedback_attachments}}", context: context(with: []))
        XCTAssertEqual(out, "Att: ")
    }

    func test_placeholder_renders_image_and_file_html_block() {
        let atts = [
            FeedbackAttachmentRef(
                filename: "shot.png", mimeType: "image/png",
                url: URL(string: "https://example.com/shot.png")!, sizeBytes: 1024
            ),
            FeedbackAttachmentRef(
                filename: "log.txt", mimeType: "text/plain",
                url: URL(string: "https://example.com/log.txt?a=1&b=2")!, sizeBytes: 512
            ),
        ]
        let composer = MailComposer()
        let out = composer.applyPlaceholders("X{{feedback_attachments}}Y", context: context(with: atts))
        XCTAssertTrue(out.contains("<img src=\"https://example.com/shot.png\""))
        XCTAssertTrue(out.contains("alt=\"shot.png\""))
        XCTAssertTrue(out.contains("<a href=\"https://example.com/log.txt?a=1&amp;b=2\">log.txt</a>"),
                      "ampersand in URL must be HTML-encoded")
        XCTAssertTrue(out.hasPrefix("X"))
        XCTAssertTrue(out.hasSuffix("Y"))
    }
}
