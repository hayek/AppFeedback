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

    // MARK: - Task 3: submit / delete / error mapping

    func testSubmitUpsertsAndStoresPendingState() async throws {
        let pid = UUID()
        let store = try seededStore(reviewId: "rev-1", responseId: nil, state: nil,
                                    productID: pid, issueNumber: 1)
        let client = RecordingASCClient()
        let c = AppStoreResponseController(
            reviewId: "rev-1", productID: pid, issueNumber: 1, repoOwner: "o", repoName: "r",
            client: client, mirrorStore: store, commentPoster: GitHubCommentPoster(),
            tokenLoader: { nil }, readOnly: false)   // nil token → comment post skipped, upsert still asserted
        c.draft = "Thanks for the review!"

        await c.submit()

        let calls = await client.recordedCalls()
        XCTAssertEqual(calls, [.upsert(reviewId: "rev-1", body: "Thanks for the review!")])
        XCTAssertEqual(store.mirror(reviewId: "rev-1")?.responseId, "resp-new")
        XCTAssertEqual(store.mirror(reviewId: "rev-1")?.responseState, "PENDING_PUBLISH")
        XCTAssertNil(c.lastError)
        XCTAssertEqual(c.mode, .hasResponse)
    }

    func testSubmit403DisablesPanel() async throws {
        let pid = UUID()
        let store = try seededStore(reviewId: "rev-1", responseId: nil, state: nil,
                                    productID: pid, issueNumber: 1)
        let client = RecordingASCClient()
        await client.setUpsert { throw StubStatusError(statusCode: 403) }
        let c = AppStoreResponseController(
            reviewId: "rev-1", productID: pid, issueNumber: 1, repoOwner: "o", repoName: "r",
            client: client, mirrorStore: store, commentPoster: GitHubCommentPoster(),
            tokenLoader: { nil }, readOnly: false)
        c.draft = "Thanks!"

        await c.submit()

        XCTAssertEqual(c.mode, .disabledReadOnly)
        XCTAssertNil(store.mirror(reviewId: "rev-1")?.responseId)  // nothing persisted on 403
    }

    // Belt-and-suspenders: the REAL Phase-3 error must drive the same read-only disable,
    // both via its StatusCarryingError conformance and the direct `.forbidden` match.
    func testSubmitRealAppStoreConnectForbiddenDisablesPanel() async throws {
        let pid = UUID()
        let store = try seededStore(reviewId: "rev-1", responseId: nil, state: nil,
                                    productID: pid, issueNumber: 1)
        let client = RecordingASCClient()
        await client.setUpsert { throw AppStoreConnectError.forbidden }
        let c = AppStoreResponseController(
            reviewId: "rev-1", productID: pid, issueNumber: 1, repoOwner: "o", repoName: "r",
            client: client, mirrorStore: store, commentPoster: GitHubCommentPoster(),
            tokenLoader: { nil }, readOnly: false)
        c.draft = "Thanks!"

        await c.submit()

        XCTAssertEqual(c.mode, .disabledReadOnly)
        XCTAssertNil(store.mirror(reviewId: "rev-1")?.responseId)  // nothing persisted on a real 403
    }

    func testSubmit422SurfacesValidationError() async throws {
        let pid = UUID()
        let store = try seededStore(reviewId: "rev-1", responseId: nil, state: nil,
                                    productID: pid, issueNumber: 1)
        let client = RecordingASCClient()
        await client.setUpsert { throw StubStatusError(statusCode: 422) }
        let c = AppStoreResponseController(
            reviewId: "rev-1", productID: pid, issueNumber: 1, repoOwner: "o", repoName: "r",
            client: client, mirrorStore: store, commentPoster: GitHubCommentPoster(),
            tokenLoader: { nil }, readOnly: false)
        c.draft = "Thanks!"

        await c.submit()

        if case .validation = c.lastError {} else { XCTFail("expected .validation, got \(String(describing: c.lastError))") }
    }

    func testSubmitOverLimitGuardsBeforeNetwork() async throws {
        let pid = UUID()
        let store = try seededStore(reviewId: "rev-1", responseId: nil, state: nil,
                                    productID: pid, issueNumber: 1)
        let client = RecordingASCClient()
        let c = AppStoreResponseController(
            reviewId: "rev-1", productID: pid, issueNumber: 1, repoOwner: "o", repoName: "r",
            client: client, mirrorStore: store, commentPoster: GitHubCommentPoster(),
            tokenLoader: { nil }, readOnly: false)
        c.draft = String(repeating: "x", count: AppStoreResponseController.maxBodyLength + 1)

        await c.submit()

        let calls = await client.recordedCalls()
        XCTAssertTrue(calls.isEmpty)  // never hits the network
        if case .tooLong(let over) = c.lastError { XCTAssertEqual(over, 1) }
        else { XCTFail("expected .tooLong") }
    }

    func testDeleteRemovesResponseAndClearsMirror() async throws {
        let pid = UUID()
        let store = try seededStore(reviewId: "rev-1", responseId: "resp-existing", state: "PUBLISHED",
                                    productID: pid, issueNumber: 1)
        let client = RecordingASCClient()
        let c = AppStoreResponseController(
            reviewId: "rev-1", productID: pid, issueNumber: 1, repoOwner: "o", repoName: "r",
            client: client, mirrorStore: store, commentPoster: GitHubCommentPoster(),
            tokenLoader: { nil }, readOnly: false)
        XCTAssertEqual(c.mode, .hasResponse)

        await c.delete()

        let calls = await client.recordedCalls()
        XCTAssertEqual(calls, [.delete(responseId: "resp-existing")])
        XCTAssertNil(store.mirror(reviewId: "rev-1")?.responseId)
        XCTAssertNil(store.mirror(reviewId: "rev-1")?.responseState)
        XCTAssertEqual(c.mode, .noResponse)
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

// MARK: - Task 3 helpers

private struct StubStatusError: StatusCarryingError { let statusCode: Int }

private actor RecordingASCClient: AppStoreConnectClientProtocol {
    enum Call: Equatable { case upsert(reviewId: String, body: String); case delete(responseId: String) }
    private(set) var calls: [Call] = []
    var upsertResult: @Sendable () throws -> ASCResponse = {
        ASCResponse(id: "resp-new", responseBody: "ok", state: "PENDING_PUBLISH", lastModifiedDate: Date())
    }
    var deleteError: Error?

    func setUpsert(_ block: @escaping @Sendable () throws -> ASCResponse) { upsertResult = block }
    func setDeleteError(_ e: Error?) { deleteError = e }
    func recordedCalls() -> [Call] { calls }

    func listReviews(appAppleID: String, page cursor: String?) async throws -> ASCReviewPage {
        ASCReviewPage(reviews: [], nextCursor: nil, rateRemaining: nil)
    }
    func listApps() async throws -> [ASCApp] { [] }
    func createOrUpdateResponse(reviewId: String, body: String) async throws -> ASCResponse {
        calls.append(.upsert(reviewId: reviewId, body: body))
        return try upsertResult()
    }
    func deleteResponse(responseId: String) async throws {
        calls.append(.delete(responseId: responseId))
        if let deleteError { throw deleteError }
    }
}

@MainActor
private func seededStore(reviewId: String, responseId: String?, state: String?,
                         productID: UUID, issueNumber: Int) throws -> AppStoreReviewMirrorStore {
    let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
    let container = try ModelContainer(for: AppStoreReviewMirror.self, configurations: config)
    let context = ModelContext(container)
    context.insert(AppStoreReviewMirror(
        reviewId: reviewId, productID: productID, issueNumber: issueNumber,
        contentHash: "h", responseState: state, responseId: responseId))
    try context.save()
    return AppStoreReviewMirrorStore(context: context)
}
