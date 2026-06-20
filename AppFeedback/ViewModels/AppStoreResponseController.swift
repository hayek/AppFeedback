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

// MARK: - Task 3: submit / delete / error mapping

extension AppStoreResponseController {
    /// Submit (or edit — ASC has no PATCH, the POST is an upsert) the developer response.
    /// On success persists `responseId`/state to the mirror and drops a GitHub comment for
    /// cross-device record. Guards the char limit before any network call.
    func submit() async {
        guard mode != .disabledReadOnly else { return }
        lastError = nil
        let body = trimmedDraft
        guard !body.isEmpty else { return }
        if draft.count > Self.maxBodyLength {
            lastError = .tooLong(draft.count - Self.maxBodyLength)
            return
        }

        isBusy = true
        defer { isBusy = false }
        do {
            let response = try await client.createOrUpdateResponse(reviewId: reviewId, body: body)
            mirrorStore.setResponse(reviewId: reviewId, responseId: response.id, state: response.state)
            await postRecordComment(action: "Responded on App Store (pending)", body: body)
        } catch {
            applyWriteError(error)
        }
    }

    /// Delete the developer response and clear the mirror's response fields.
    func delete() async {
        guard mode == .hasResponse,
              let responseId = mirrorStore.mirror(reviewId: reviewId)?.responseId else { return }
        lastError = nil
        isBusy = true
        defer { isBusy = false }
        do {
            try await client.deleteResponse(responseId: responseId)
            mirrorStore.clearResponse(reviewId: reviewId)
            draft = ""
            await postRecordComment(action: "Deleted App Store response", body: nil)
        } catch {
            applyWriteError(error)
        }
    }

    /// Posts a record comment to the synthesized GitHub issue (best-effort; a missing token
    /// or a post failure never fails the write-back — the ASC change already landed).
    private func postRecordComment(action: String, body: String?) async {
        guard let token = await tokenLoader() else { return }
        let text: String = body.map { "\(action): \($0)" } ?? action
        _ = try? await commentPoster.postComment(
            owner: repoOwner, repo: repoName, issueNumber: issueNumber, body: text, token: token)
    }

    /// Maps an ASC write failure into the panel's error/disabled state. A 403 is matched
    /// two ways: a direct `AppStoreConnectError.forbidden` case (belt) AND any
    /// `StatusCarryingError` whose `statusCode == 403` (suspenders) — so the read-only
    /// disable fires for the real Phase-3 error and any other status-carrying error alike.
    private func applyWriteError(_ error: Error) {
        // Belt: the concrete Phase-3 forbidden case.
        if case AppStoreConnectError.forbidden = error {
            discoveredReadOnly = true                  // read-only key → disable the panel
            return
        }
        // Suspenders: any status-carrying error (incl. AppStoreConnectError via its conformance).
        if let coded = error as? StatusCarryingError {
            switch coded.statusCode {
            case 403: discoveredReadOnly = true        // read-only key → disable the panel
            case 409: lastError = .conflict
            case 422: lastError = .validation("App Store rejected the response text.")
            default:  lastError = .api(coded.statusCode, nil)
            }
            return
        }
        if let postError = error as? GitHubCommentPoster.PostError,
           case let .apiError(code, message) = postError {
            lastError = .api(code, message)
            return
        }
        lastError = .network((error as NSError).localizedDescription)
    }
}
