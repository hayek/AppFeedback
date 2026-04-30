import XCTest
@testable import AppFeedback

@MainActor
final class MailToGitHubMirrorTests: XCTestCase {

    func test_redact_keepsFirstCharAndDomain() {
        XCTAssertEqual(MailToGitHubMirror.redact("alice@example.com"), "a***@example.com")
        XCTAssertEqual(MailToGitHubMirror.redact("b@host.tld"),        "b***@host.tld")
    }

    func test_redact_emailMissingAtSign_returnedAsIs() {
        XCTAssertEqual(MailToGitHubMirror.redact("not-an-email"), "not-an-email")
    }

    func test_redact_emptyLocalPart_returnedAsIs() {
        XCTAssertEqual(MailToGitHubMirror.redact("@example.com"), "@example.com")
    }

    func test_buildCommentBody_inboundRedactedForPublicRepo() {
        let msg = MailMessage(
            messageID: "m1",
            fromAddress: "alice@example.com",
            toAddresses: ["dev@us.com"],
            date: Date(timeIntervalSince1970: 1714477200),
            subject: "Re: Crash on launch",
            bodyPlain: "Still happening on 2.1\n\nOn Tue, someone wrote:\n> earlier text",
            directionRaw: MailMessage.Direction.inbound.rawValue
        )
        let body = MailToGitHubMirror.buildCommentBody(message: msg, redactEmail: true)
        XCTAssertTrue(body.contains("📥 Reply from a***@example.com"))
        XCTAssertTrue(body.contains("> Still happening on 2.1"))
        // Quoted history should be stripped from the mirrored body.
        XCTAssertFalse(body.contains("earlier text"))
        XCTAssertTrue(body.contains("Mirrored automatically by AppFeedback"))
    }

    func test_buildCommentBody_outboundShowsRecipientAndKeepsAddressOnPrivate() {
        let msg = MailMessage(
            messageID: "m2",
            fromAddress: "dev@us.com",
            toAddresses: ["alice@example.com"],
            date: Date(timeIntervalSince1970: 1714477200),
            subject: "Re: Crash on launch",
            bodyPlain: "Thanks for the report — fix in 2.2.",
            directionRaw: MailMessage.Direction.outbound.rawValue
        )
        let body = MailToGitHubMirror.buildCommentBody(message: msg, redactEmail: false)
        XCTAssertTrue(body.contains("📤 Sent to alice@example.com"))
        XCTAssertTrue(body.contains("> Thanks for the report"))
    }
}
