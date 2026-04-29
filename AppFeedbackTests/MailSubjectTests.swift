import XCTest
@testable import AppFeedback

final class MailSubjectTests: XCTestCase {

    func test_replyPrefixed_addsPrefixToBareSubject() {
        XCTAssertEqual(MailSubject.replyPrefixed("foo"), "Re: foo")
    }

    func test_replyPrefixed_idempotent() {
        XCTAssertEqual(MailSubject.replyPrefixed("Re: foo"), "Re: foo")
    }

    func test_replyPrefixed_collapsesChainedPrefixes() {
        XCTAssertEqual(MailSubject.replyPrefixed("RE:Re:Fwd: foo"), "Re: foo")
    }

    func test_replyPrefixed_emptyString() {
        XCTAssertEqual(MailSubject.replyPrefixed(""), "Re: ")
    }

    func test_replyPrefixed_trimsLeadingWhitespace() {
        XCTAssertEqual(MailSubject.replyPrefixed("   foo  "), "Re: foo")
    }
}
