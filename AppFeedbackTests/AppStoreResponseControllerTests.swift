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

    // MARK: - Task 2: char-limit + derived state

    // A no-op fake client; network-call assertions arrive in Task 3.
    private func makeController(
        readOnly: Bool = false,
        client: any AppStoreConnectClientProtocol = FakeASCClient(),
        mirrorStore: AppStoreReviewMirrorStore? = nil
    ) throws -> AppStoreResponseController {
        let store: AppStoreReviewMirrorStore
        if let mirrorStore { store = mirrorStore } else {
            let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
            let container = try ModelContainer(for: AppStoreReviewMirror.self, configurations: config)
            store = AppStoreReviewMirrorStore(context: ModelContext(container))
        }
        return AppStoreResponseController(
            reviewId: "rev-1", productID: UUID(), issueNumber: 1,
            repoOwner: "o", repoName: "r",
            client: client, mirrorStore: store,
            commentPoster: GitHubCommentPoster(),
            tokenLoader: { "tok" }, readOnly: readOnly)
    }

    func testRemainingCharsAndOverLimit() throws {
        let c = try makeController()
        c.draft = String(repeating: "x", count: AppStoreResponseController.maxBodyLength + 5)
        XCTAssertEqual(c.remainingChars, -5)
        XCTAssertTrue(c.overLimit)
        XCTAssertFalse(c.canSubmit)
    }

    func testCannotSubmitEmptyDraft() throws {
        let c = try makeController()
        c.draft = "   "
        XCTAssertFalse(c.canSubmit)
    }

    func testCanSubmitValidDraft() throws {
        let c = try makeController()
        c.draft = "Thanks for the feedback!"
        XCTAssertTrue(c.canSubmit)
        XCTAssertEqual(c.mode, .noResponse)
    }

    func testReadOnlyKeyDisablesPanel() throws {
        let c = try makeController(readOnly: true)
        c.draft = "Thanks!"
        XCTAssertEqual(c.mode, .disabledReadOnly)
        XCTAssertFalse(c.canSubmit)
    }
}

// MARK: - Fake clients (shared across tasks)

private actor FakeASCClient: AppStoreConnectClientProtocol {
    func listReviews(appAppleID: String, page cursor: String?) async throws -> ASCReviewPage {
        ASCReviewPage(reviews: [], nextCursor: nil, rateRemaining: nil)
    }
    func listApps() async throws -> [ASCApp] { [] }
    func createOrUpdateResponse(reviewId: String, body: String) async throws -> ASCResponse {
        ASCResponse(id: "resp", responseBody: body, state: "PENDING_PUBLISH", lastModifiedDate: Date())
    }
    func deleteResponse(responseId: String) async throws {}
}
