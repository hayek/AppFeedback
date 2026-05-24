import XCTest
@testable import AppFeedback

final class IssueBodyParserShimAttachmentsTests: XCTestCase {

    func test_shim_passes_attachments_through() {
        let body = """
        Description.

        <!-- attachments-v1 -->
        ## Attachments

        ![s.png](https://example.com/s.png) — image/png, 1 KB

        <!-- /attachments-v1 -->

        ---
        👍 Votes: 0
        """
        let parsed = IssueBodyParser.parse(body)
        XCTAssertEqual(parsed.attachments.count, 1)
        XCTAssertEqual(parsed.attachments[0].filename, "s.png")
        XCTAssertEqual(parsed.attachments[0].mimeType, "image/png")
    }
}
