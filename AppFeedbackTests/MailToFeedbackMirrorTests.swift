import XCTest
import AppFeedbackCore
@testable import AppFeedback

@MainActor
final class MailToFeedbackMirrorTests: XCTestCase {

    private func parsed(
        messageID: String = "<root@x>",
        from: String = "alice@example.com",
        subject: String = "App crashes on launch",
        bodyPlain: String = "It crashes every time I open the camera.",
        bodyHTML: String? = nil
    ) -> ParsedInboundMessage {
        ParsedInboundMessage(
            uid: 10, folder: "INBOX", uidValidity: 1, messageID: messageID,
            inReplyTo: nil, references: [],
            fromAddress: from, fromName: "Alice",
            toAddresses: ["feedback@dev.com"], ccAddresses: [],
            date: Date(timeIntervalSince1970: 1_714_477_200),
            subject: subject, bodyPlain: bodyPlain, bodyHTML: bodyHTML,
            attachments: []
        )
    }

    func test_issueTitle_usesSubject() {
        XCTAssertEqual(MailToFeedbackMirror.issueTitle(subject: "Bug here"), "Bug here")
    }

    func test_issueTitle_emptySubject_fallsBackToNoSubject() {
        XCTAssertEqual(MailToFeedbackMirror.issueTitle(subject: ""), "(no subject)")
        XCTAssertEqual(MailToFeedbackMirror.issueTitle(subject: "   "), "(no subject)")
    }

    func test_sourceEmailLabel_isExact() {
        XCTAssertEqual(MailToFeedbackMirror.sourceEmailLabel, "source:email")
    }

    // ★ MARKER FORMAT CORRECTION: markers are written via IssueBodyFormatter.sourceMetadataBlock
    // (source-meta-v1 HTML-comment-fenced block), NOT **Key:** lines.
    func test_issueBody_usesSourceMetaBlock_withEmailSource() {
        let body = MailToFeedbackMirror.issueBody(message: parsed(), redactEmail: false)
        // The body must carry the HTML-comment-fenced source-meta-v1 block.
        XCTAssertTrue(body.contains("<!-- source-meta-v1 -->"),
                      "body must use SDK sourceMetadataBlock, not ad-hoc **Key:** lines")
        XCTAssertTrue(body.contains("source: email"))
        XCTAssertTrue(body.contains("fromAddress: alice@example.com"))
        XCTAssertTrue(body.contains("messageId: <root@x>"))
        XCTAssertTrue(body.contains("It crashes every time I open the camera."))
    }

    func test_issueBody_redactsFromAddress() {
        let body = MailToFeedbackMirror.issueBody(message: parsed(), redactEmail: true)
        XCTAssertTrue(body.contains("fromAddress: a***@example.com"))
        XCTAssertFalse(body.contains("alice@example.com"))
    }

    func test_issueBody_keepsAddressWhenNotRedacted() {
        let body = MailToFeedbackMirror.issueBody(message: parsed(), redactEmail: false)
        XCTAssertTrue(body.contains("fromAddress: alice@example.com"))
    }

    func test_preferredBodyText_prefersPlainThenStrippedHTML() {
        // plain present → plain wins
        XCTAssertEqual(
            MailToFeedbackMirror.preferredBodyText(message: parsed(bodyPlain: "PLAIN", bodyHTML: "<p>HTML</p>")),
            "PLAIN"
        )
        // plain empty → HTML stripped to plain text
        let stripped = MailToFeedbackMirror.preferredBodyText(
            message: parsed(bodyPlain: "  ", bodyHTML: "<p>Hello <b>there</b></p>")
        )
        XCTAssertTrue(stripped.contains("Hello"))
        XCTAssertTrue(stripped.contains("there"))
        XCTAssertFalse(stripped.contains("<p>"))
    }

    // MARK: - Round-trip test (the critical one per the plan requirements)
    // Built body → IssueBodyParser → source==.email, fromAddress recovered, messageId recovered.

    func test_issueBody_roundTrips_sourceEmailFromAddressMessageId() {
        let msg = parsed(messageID: "<roundtrip@x>", from: "user@example.com")
        let body = MailToFeedbackMirror.issueBody(message: msg, redactEmail: false)
        let parsed = AppFeedback.IssueBodyParser.parse(body)
        XCTAssertEqual(parsed.source, FeedbackSource.email.rawValue,
                       "IssueBodyParser must recover source == .email from the sourceMetadataBlock")
        XCTAssertEqual(parsed.fromAddress, "user@example.com",
                       "IssueBodyParser must recover fromAddress from the sourceMetadataBlock")
        XCTAssertEqual(parsed.messageId, "<roundtrip@x>",
                       "IssueBodyParser must recover messageId from the sourceMetadataBlock")
        XCTAssertNil(parsed.rating, "email feedback carries no rating")
    }

    func test_issueBody_roundTrips_redactedAddress() {
        let msg = parsed(messageID: "<redact@x>", from: "alice@example.com")
        let body = MailToFeedbackMirror.issueBody(message: msg, redactEmail: true)
        let parsed = AppFeedback.IssueBodyParser.parse(body)
        XCTAssertEqual(parsed.source, FeedbackSource.email.rawValue)
        XCTAssertEqual(parsed.fromAddress, "a***@example.com",
                       "redacted address must survive the round-trip through IssueBodyParser")
        XCTAssertEqual(parsed.messageId, "<redact@x>")
    }
}
