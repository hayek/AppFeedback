import XCTest
@testable import AppFeedback

/// Smoke test — verifies `IssueWriting` and `FakeIssueWriting` compile and link correctly.
/// Real coordinator tests are added in later tasks once the coordinator actor exists.
final class AppStoreReviewCoordinatorTests: XCTestCase {
    func testFakeIssueWritingConformsToProtocol() async throws {
        let fake: any IssueWriting = FakeIssueWriting(startingNumber: 42)
        let number = try await fake.createIssue(
            owner: "o", repo: "r", title: "t", body: "b",
            labels: [], milestoneNumber: nil, token: "tok")
        XCTAssertEqual(number, 42)
    }
}
