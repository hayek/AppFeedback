import Foundation
import Observation

/// Drives the "Respond on App Store" panel for a single App Store feedback item. Owns the
/// editor draft, validates against the (community-observed) length cap, and — in Task 3 —
/// performs the upsert/delete via `AppStoreConnectClientProtocol`, persists the
/// `responseId`/`responseState` through `AppStoreReviewMirrorStore`, and drops a GitHub
/// comment for cross-device record. A read-only ASC key (or a live 403) disables editing.
@Observable @MainActor
final class AppStoreResponseController {
    /// Community-observed `responseBody` ceiling (Apple does not document it). We validate
    /// client-side and still handle 422/409 defensively (Task 3).
    static let maxBodyLength = 5970

    enum Mode: Equatable {
        case noResponse          // no developer response yet → "Submit"
        case hasResponse         // a response exists → "Edit" / "Delete"
        case disabledReadOnly    // read-only key or a 403 → panel shown but inert
    }

    enum SubmitError: Equatable {
        case tooLong(Int)        // associated value = chars over the limit
        case conflict            // 409
        case validation(String)  // 422
        case api(Int, String?)
        case network(String)
    }

    var draft: String = ""
    private(set) var isBusy = false
    private(set) var lastError: SubmitError?
    /// Set true once a live call returns 403 (read-only key discovered at write time).
    private(set) var discoveredReadOnly = false

    let reviewId: String
    let productID: UUID
    let issueNumber: Int
    let repoOwner: String
    let repoName: String

    private let client: any AppStoreConnectClientProtocol
    private let mirrorStore: AppStoreReviewMirrorStore
    private let commentPoster: GitHubCommentPoster
    private let tokenLoader: @Sendable () async -> String?
    private let initialReadOnly: Bool

    init(
        reviewId: String,
        productID: UUID,
        issueNumber: Int,
        repoOwner: String,
        repoName: String,
        client: any AppStoreConnectClientProtocol,
        mirrorStore: AppStoreReviewMirrorStore,
        commentPoster: GitHubCommentPoster,
        tokenLoader: @escaping @Sendable () async -> String?,
        readOnly: Bool
    ) {
        self.reviewId = reviewId
        self.productID = productID
        self.issueNumber = issueNumber
        self.repoOwner = repoOwner
        self.repoName = repoName
        self.client = client
        self.mirrorStore = mirrorStore
        self.commentPoster = commentPoster
        self.tokenLoader = tokenLoader
        self.initialReadOnly = readOnly
        // Seed the editor from any existing response state isn't possible from the mirror
        // (it stores id/state, not the body); the editor starts empty and the existing
        // response body, when present, is shown read-only beside the editor by the panel.
    }

    // MARK: Derived state

    private var existingResponseId: String? {
        mirrorStore.mirror(reviewId: reviewId)?.responseId
    }

    var responseState: String? {
        mirrorStore.mirror(reviewId: reviewId)?.responseState
    }

    var mode: Mode {
        if initialReadOnly || discoveredReadOnly { return .disabledReadOnly }
        return existingResponseId == nil ? .noResponse : .hasResponse
    }

    var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var remainingChars: Int { Self.maxBodyLength - draft.count }
    var overLimit: Bool { draft.count > Self.maxBodyLength }

    var canSubmit: Bool {
        guard mode != .disabledReadOnly, !isBusy else { return false }
        return !trimmedDraft.isEmpty && !overLimit
    }

    /// Delete is only meaningful when a response already exists and the key can write.
    var canDelete: Bool {
        mode == .hasResponse && !isBusy
    }
}
