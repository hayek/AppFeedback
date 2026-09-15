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

    func test_country_name_resolves_alpha3_territory() {
        let en = Locale(identifier: "en_US")
        XCTAssertEqual(SourceBadge.countryName(source: .appStore, territory: "GBR", locale: en), "United Kingdom")
        XCTAssertEqual(SourceBadge.countryName(source: .appStore, territory: "ZZZ", locale: en), "ZZZ")
    }

    func test_country_name_hidden_without_territory_or_for_other_sources() {
        XCTAssertNil(SourceBadge.countryName(source: .appStore, territory: nil))
        XCTAssertNil(SourceBadge.countryName(source: .appStore, territory: ""))
        XCTAssertNil(SourceBadge.countryName(source: .email, territory: "USA"))
    }

    func test_territory_survives_parse_and_cache_roundtrip() {
        let review = ASCReview(id: "R1", rating: 4, title: "Nice", body: "Works", reviewerNickname: "sam",
                               createdDate: Date(timeIntervalSince1970: 1_700_000_000), territory: "DEU", response: nil)
        let body = AppStoreReviewSynthesizer.body(for: review)
        XCTAssertEqual(IssueBodyParser.parse(body).territory, "DEU")

        let issue = FeedbackIssue(
            number: 1, title: "Nice", createdAt: Date(), rawBody: body,
            appName: nil, appVersion: nil, device: nil, osVersion: nil, email: nil,
            description: "Works", labels: [], source: .appStore, rating: 4, territory: "DEU"
        )
        let restored = CachedIssue.from(issue, repoOwner: "o", repoName: "r").toFeedbackIssue()
        XCTAssertEqual(restored.territory, "DEU")
        XCTAssertEqual(restored.createdAt, review.createdDate)
    }
}
