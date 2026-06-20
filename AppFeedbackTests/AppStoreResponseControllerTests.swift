import XCTest
import SwiftData
@testable import AppFeedback

@MainActor
final class AppStoreResponseControllerTests: XCTestCase {
    func testReviewIdExtractedFromMarkerLine() {
        let body = """
        Loved the update!

        reviewId: 1234567890ABCDEF
        source: app-store
        rating: 5
        """
        XCTAssertEqual(AppStoreReviewIdExtractor.reviewId(fromBody: body), "1234567890ABCDEF")
    }

    func testReviewIdMissingReturnsNil() {
        XCTAssertNil(AppStoreReviewIdExtractor.reviewId(fromBody: "no markers here"))
    }

    func testReviewIdToleratesExtraWhitespace() {
        XCTAssertEqual(
            AppStoreReviewIdExtractor.reviewId(fromBody: "reviewId:   abc-123  "),
            "abc-123")
    }
}
