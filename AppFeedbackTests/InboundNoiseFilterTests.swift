import XCTest
@testable import AppFeedback

final class InboundNoiseFilterTests: XCTestCase {
    private func msg(
        from: String = "alice@example.com",
        returnPath: String? = "alice@example.com",
        autoSubmitted: String? = nil,
        precedence: String? = nil
    ) -> ParsedInboundMessage {
        ParsedInboundMessage(
            uid: 1, folder: "INBOX", uidValidity: 1, messageID: "<m1@x>",
            inReplyTo: nil, references: [],
            fromAddress: from, fromName: nil,
            toAddresses: ["inbox@dev.com"], ccAddresses: [],
            date: Date(), subject: "Hi", bodyPlain: "feedback", bodyHTML: nil,
            attachments: [],
            returnPath: returnPath, autoSubmitted: autoSubmitted, precedence: precedence
        )
    }

    func test_cleanMessage_isNotNoise() {
        XCTAssertFalse(InboundNoiseFilter.isNoise(msg()))
    }

    func test_mailerDaemonSender_isNoise() {
        XCTAssertTrue(InboundNoiseFilter.isNoise(msg(from: "MAILER-DAEMON@mail.google.com")))
        XCTAssertTrue(InboundNoiseFilter.isNoise(msg(from: "postmaster@example.com")))
    }

    func test_emptyReturnPath_isNoise() {
        XCTAssertTrue(InboundNoiseFilter.isNoise(msg(returnPath: "")))
        XCTAssertTrue(InboundNoiseFilter.isNoise(msg(returnPath: "<>")))
    }

    func test_autoSubmittedAuto_isNoise_butNotNo() {
        XCTAssertTrue(InboundNoiseFilter.isNoise(msg(autoSubmitted: "auto-replied")))
        XCTAssertTrue(InboundNoiseFilter.isNoise(msg(autoSubmitted: "auto-generated")))
        // "no" is the explicit human-sent value and must NOT be filtered.
        XCTAssertFalse(InboundNoiseFilter.isNoise(msg(autoSubmitted: "no")))
    }

    func test_precedenceBulkOrList_isNoise() {
        XCTAssertTrue(InboundNoiseFilter.isNoise(msg(precedence: "bulk")))
        XCTAssertTrue(InboundNoiseFilter.isNoise(msg(precedence: "list")))
        XCTAssertFalse(InboundNoiseFilter.isNoise(msg(precedence: "normal")))
    }
}
