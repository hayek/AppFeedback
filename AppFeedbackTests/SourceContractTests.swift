import XCTest
import AppFeedbackCore
@testable import AppFeedback

final class SourceContractTests: XCTestCase {

    func test_shim_reads_app_store_source_and_rating() {
        let block = AppFeedbackCore.IssueBodyFormatter.sourceMetadataBlock(
            source: "app-store", rating: 3, reviewerNickname: "Sam", territory: "USA",
            reviewId: "rv-7", reviewCreatedAt: nil, fromAddress: nil, messageId: nil
        )
        let parsed = AppFeedback.IssueBodyParser.parse("Great app\n\n" + block)
        XCTAssertEqual(parsed.source, "app-store")
        XCTAssertEqual(parsed.rating, 3)
        XCTAssertEqual(parsed.reviewId, "rv-7")
    }

    func test_shim_reads_email_source() {
        let block = AppFeedbackCore.IssueBodyFormatter.sourceMetadataBlock(
            source: "email", rating: nil, reviewerNickname: nil, territory: nil,
            reviewId: nil, reviewCreatedAt: nil, fromAddress: "a@b.com", messageId: "<m1>"
        )
        let parsed = AppFeedback.IssueBodyParser.parse(block)
        XCTAssertEqual(parsed.source, "email")
        XCTAssertEqual(parsed.fromAddress, "a@b.com")
        XCTAssertEqual(parsed.messageId, "<m1>")
        XCTAssertNil(parsed.rating)
    }

    func test_legacy_body_has_nil_source() {
        let parsed = AppFeedback.IssueBodyParser.parse("Plain SDK feedback.\n\n---\n👍 Votes: 0")
        XCTAssertNil(parsed.source)
        XCTAssertNil(parsed.rating)
    }

    func test_cachedIssue_roundtrips_source_rating() {
        let issue = FeedbackIssue(
            number: 1, title: "T", createdAt: Date(), rawBody: "b",
            appName: nil, appVersion: nil, device: nil, osVersion: nil, email: nil,
            description: "d", labels: [], source: .appStore, rating: 5
        )
        let cached = CachedIssue.from(issue, repoOwner: "o", repoName: "r")
        XCTAssertEqual(cached.source, "app-store")
        XCTAssertEqual(cached.rating, 5)
        let back = cached.toFeedbackIssue()
        XCTAssertEqual(back.source, .appStore)
        XCTAssertEqual(back.rating, 5)
    }

    func test_cachedIssue_legacy_nil_source_maps_to_sdk() {
        let issue = FeedbackIssue(
            number: 2, title: "T", createdAt: Date(), rawBody: "b",
            appName: nil, appVersion: nil, device: nil, osVersion: nil, email: nil,
            description: "d", labels: []
        )
        let cached = CachedIssue.from(issue, repoOwner: "o", repoName: "r")
        cached.source = nil          // simulate a legacy row cached before Phase 1
        cached.rating = nil
        XCTAssertEqual(cached.toFeedbackIssue().source, .sdk)
        XCTAssertNil(cached.toFeedbackIssue().rating)
    }

    func test_source_resolution_marker_wins_then_label_then_sdk() {
        // marker present
        XCTAssertEqual(
            IssueLoader.resolveSource(markerSource: "email", labels: ["source:app-store"]),
            .email
        )
        // no marker → label fallback
        XCTAssertEqual(
            IssueLoader.resolveSource(markerSource: nil, labels: ["source:app-store"]),
            .appStore
        )
        // neither → sdk
        XCTAssertEqual(IssueLoader.resolveSource(markerSource: nil, labels: ["bug"]), .sdk)
    }

    func test_rating_resolution_marker_wins_then_label() {
        XCTAssertEqual(IssueLoader.resolveRating(markerRating: 4, labels: ["rating:2"]), 4)
        XCTAssertEqual(IssueLoader.resolveRating(markerRating: nil, labels: ["rating:2"]), 2)
        XCTAssertNil(IssueLoader.resolveRating(markerRating: nil, labels: ["bug"]))
    }
}
