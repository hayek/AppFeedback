import XCTest
@testable import AppFeedback

final class HTMLSanitizerTests: XCTestCase {

    func test_keepsAllowedTags() {
        let input = "<p>Hello <strong>world</strong></p>"
        XCTAssertEqual(HTMLSanitizer.sanitize(input), "<p>Hello <strong>world</strong></p>")
    }

    func test_dropsScriptTag() {
        let input = "<p>ok</p><script>alert(1)</script>"
        let out = HTMLSanitizer.sanitize(input)
        XCTAssertFalse(out.contains("<script"))
        XCTAssertFalse(out.contains("alert"))
        XCTAssertTrue(out.contains("<p>ok</p>"))
    }

    func test_dropsStyleTag() {
        let input = "<style>p { color: red }</style><p>x</p>"
        let out = HTMLSanitizer.sanitize(input)
        XCTAssertFalse(out.contains("<style"))
        XCTAssertFalse(out.contains("color: red"))
    }

    func test_dropsInlineEventHandlers() {
        let input = #"<p onclick="evil()">x</p>"#
        let out = HTMLSanitizer.sanitize(input)
        XCTAssertFalse(out.contains("onclick"))
        XCTAssertFalse(out.contains("evil"))
        XCTAssertTrue(out.contains("<p>x</p>"))
    }

    func test_keepsLinkHref() {
        let input = #"<a href="https://example.com">link</a>"#
        let out = HTMLSanitizer.sanitize(input)
        XCTAssertTrue(out.contains("href=\"https://example.com\""))
    }

    func test_dropsJavascriptHref() {
        let input = #"<a href="javascript:alert(1)">x</a>"#
        let out = HTMLSanitizer.sanitize(input)
        XCTAssertFalse(out.contains("javascript:"))
    }

    func test_dropsUnknownTagButKeepsContent() {
        let input = "<p>Hi <marquee>scrolling</marquee> world</p>"
        let out = HTMLSanitizer.sanitize(input)
        XCTAssertFalse(out.contains("<marquee"))
        XCTAssertTrue(out.contains("scrolling"))
    }

    func test_handlesBooleanAttribute() {
        // <a download> isn't in the href allowlist, so download attr should be dropped.
        // Bare presence of a non-allowlisted attribute must not hang or corrupt output.
        let input = "<a download>x</a>"
        let out = HTMLSanitizer.sanitize(input)
        XCTAssertTrue(out.contains("<a>"))
        XCTAssertTrue(out.contains("x"))
        XCTAssertTrue(out.contains("</a>"))
    }

    func test_handlesGreaterThanInAttributeValue() {
        // A literal > inside a quoted attribute value should not terminate the tag early.
        let input2 = #"<a href="a>b">x</a>"#
        let out2 = HTMLSanitizer.sanitize(input2)
        XCTAssertTrue(out2.contains("href=\"a>b\""))
        XCTAssertTrue(out2.contains(">x</a>"))
    }

    func test_stripQuotedReply_CRLFDoesNotInsertBlankLines() {
        // IMAP delivers bodies with CRLF endings. Cleaned output must not collapse those
        // into `\n\n` (which Text renders as paragraph breaks).
        let body = "Line one\r\nLine two\r\nLine three\r\n\r\nOn Thu, 28 May 2026, X wrote:\r\n> quoted"
        let stripped = HTMLSanitizer.stripQuotedReply(body)
        XCTAssertEqual(stripped.cleaned, "Line one\nLine two\nLine three")
        XCTAssertTrue(stripped.hasQuoted)
    }

    func test_stripQuotedReply_LFOnlyStillWorks() {
        let body = "Line one\nLine two\n\nOn Thu, X wrote:\n> quoted"
        let stripped = HTMLSanitizer.stripQuotedReply(body)
        XCTAssertEqual(stripped.cleaned, "Line one\nLine two")
        XCTAssertTrue(stripped.hasQuoted)
    }
}
