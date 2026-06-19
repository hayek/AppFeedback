import XCTest
@testable import AppFeedback

final class SourceBadgeViewTests: XCTestCase {
    func test_app_store_with_rating_shows_stars() {
        XCTAssertTrue(SourceBadge.showsStars(source: .appStore, rating: 3))
        XCTAssertEqual(SourceBadge.filledStars(rating: 3), 3)
    }

    func test_rating_is_clamped_1_to_5() {
        XCTAssertEqual(SourceBadge.filledStars(rating: 0), 0)
        XCTAssertEqual(SourceBadge.filledStars(rating: 7), 5)
        XCTAssertEqual(SourceBadge.filledStars(rating: nil), 0)
    }

    func test_app_store_without_rating_hides_stars() {
        XCTAssertFalse(SourceBadge.showsStars(source: .appStore, rating: nil))
    }

    func test_non_app_store_never_shows_stars() {
        XCTAssertFalse(SourceBadge.showsStars(source: .sdk, rating: 5))
        XCTAssertFalse(SourceBadge.showsStars(source: .email, rating: 5))
    }
}
