import XCTest
@testable import AppFeedback

final class AppStoreReviewSynthesizerTests: XCTestCase {
    private func review(id: String = "R1", rating: Int = 4, title: String? = "Nice",
                        body: String? = "Body text", nick: String? = "sam",
                        territory: String = "USA") -> ASCReview {
        ASCReview(id: id, rating: rating, title: title, body: body, reviewerNickname: nick,
                  createdDate: Date(timeIntervalSince1970: 1_700_000_000), territory: territory, response: nil)
    }

    func testTitleUsesReviewTitle() {
        XCTAssertEqual(AppStoreReviewSynthesizer.title(for: review(title: "Great app")), "Great app")
    }

    func testTitleFallsBackWhenNoTitle() {
        let t = AppStoreReviewSynthesizer.title(for: review(title: nil, body: "Crashes on launch", territory: "GBR"))
        XCTAssertFalse(t.isEmpty)
        XCTAssertTrue(t.contains("★") || t.localizedCaseInsensitiveContains("review"))
    }

    func testBodyContainsAllMarkers() {
        let b = AppStoreReviewSynthesizer.body(for: review())
        XCTAssertTrue(b.contains("source: app-store"))
        XCTAssertTrue(b.contains("rating: 4"))
        XCTAssertTrue(b.contains("reviewerNickname: sam"))
        XCTAssertTrue(b.contains("territory: USA"))
        XCTAssertTrue(b.contains("reviewId: R1"))
        XCTAssertTrue(b.contains("reviewCreatedAt: "))
        XCTAssertTrue(b.contains("Body text"))
    }

    func testLabels() {
        XCTAssertEqual(AppStoreReviewSynthesizer.labels(for: review(rating: 3)),
                       ["source:app-store", "rating:3"])
    }

    func testContentHashChangesWithContent() {
        let h1 = AppStoreReviewSynthesizer.contentHash(for: review(rating: 4, title: "A", body: "B"))
        let h2 = AppStoreReviewSynthesizer.contentHash(for: review(rating: 4, title: "A", body: "B"))
        let h3 = AppStoreReviewSynthesizer.contentHash(for: review(rating: 5, title: "A", body: "B"))
        let h4 = AppStoreReviewSynthesizer.contentHash(for: review(rating: 4, title: "A", body: "B2"))
        XCTAssertEqual(h1, h2, "stable for identical content")
        XCTAssertNotEqual(h1, h3, "rating change ⇒ new hash")
        XCTAssertNotEqual(h1, h4, "body change ⇒ new hash")
        XCTAssertEqual(h1.count, 64, "SHA-256 hex")
    }
}
