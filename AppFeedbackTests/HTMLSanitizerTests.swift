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
}
