import Foundation
import os
@testable import AppFeedback

/// In-test `AppStoreConnectClientProtocol`. Returns a programmed sequence of `ASCReviewPage`s
/// (so tests can drive multi-page pagination + full re-scan), and records response create/delete
/// calls. Thread-safe via a lock since the protocol is `Sendable` and the coordinator is an actor.
final class FakeAppStoreConnectClient: AppStoreConnectClientProtocol, @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<State>(initialState: State())
    private struct State {
        var pages: [ASCReviewPage] = []      // consumed front-to-back, regardless of cursor
        var pageIndex = 0
        var apps: [ASCApp] = []
        var createCalls: [(reviewId: String, body: String)] = []
        var deleteCalls: [String] = []
        var throwOnList: Error?
        // Gate: lets a test hold `listReviews` "in flight" and observe cancellation.
        var gateArmed = false
        var gateCancelled = false
        var gateContinuation: CheckedContinuation<Void, Error>?
        var listCallCount = 0
        var listCancelCount = 0
    }

    init() {}

    // MARK: - Test seams
    func setPages(_ pages: [ASCReviewPage]) { lock.withLock { $0.pages = pages; $0.pageIndex = 0 } }
    func setApps(_ apps: [ASCApp]) { lock.withLock { $0.apps = apps } }
    func setThrowOnList(_ error: Error?) { lock.withLock { $0.throwOnList = error } }
    var createCalls: [(reviewId: String, body: String)] { lock.withLock { $0.createCalls } }
    var deleteCalls: [String] { lock.withLock { $0.deleteCalls } }

    /// Arms the gate: the next `listReviews` suspends until `releaseList()` — and throws
    /// `CancellationError` if its task is cancelled meanwhile, the way `URLSession.data(for:)`
    /// surfaces `NSURLErrorCancelled`. Lets a test hold a poll in flight and prove it survived.
    func armListGate() { lock.withLock { $0.gateArmed = true } }
    func releaseList() { takeGateContinuation()?.resume() }
    var listCallCount: Int { lock.withLock { $0.listCallCount } }
    var listCancelCount: Int { lock.withLock { $0.listCancelCount } }

    private func takeGateContinuation() -> CheckedContinuation<Void, Error>? {
        lock.withLock { state in
            defer { state.gateContinuation = nil }
            return state.gateContinuation
        }
    }

    // MARK: - Protocol
    func listReviews(appAppleID: String, page cursor: String?) async throws -> ASCReviewPage {
        let armed = lock.withLock { state -> Bool in
            state.listCallCount += 1
            return state.gateArmed
        }
        if armed { try await waitOnGate() }
        return try lock.withLock { state in
            if let e = state.throwOnList { throw e }
            guard state.pageIndex < state.pages.count else {
                return ASCReviewPage(reviews: [], nextCursor: nil, rateRemaining: nil)
            }
            defer { state.pageIndex += 1 }
            return state.pages[state.pageIndex]
        }
    }

    private func waitOnGate() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                let alreadyCancelled = lock.withLock { state -> Bool in
                    if state.gateCancelled { return true }
                    state.gateContinuation = cont
                    return false
                }
                if alreadyCancelled {
                    cont.resume(throwing: CancellationError())
                } else if Task.isCancelled {
                    // onCancel may have run before the continuation was stored.
                    takeGateContinuation()?.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            lock.withLock { $0.gateCancelled = true; $0.listCancelCount += 1 }
            takeGateContinuation()?.resume(throwing: CancellationError())
        }
    }
    func listApps() async throws -> [ASCApp] {
        try lock.withLock { state in
            if let e = state.throwOnList { throw e }
            return state.apps
        }
    }
    func createOrUpdateResponse(reviewId: String, body: String) async throws -> ASCResponse {
        lock.withLock { $0.createCalls.append((reviewId, body)) }
        return ASCResponse(id: "RESP-\(reviewId)", responseBody: body, state: "PENDING_PUBLISH", lastModifiedDate: Date())
    }
    func deleteResponse(responseId: String) async throws {
        lock.withLock { $0.deleteCalls.append(responseId) }
    }
}

extension ASCReview {
    /// Convenience builder for coordinator tests.
    static func make(id: String, rating: Int = 4, title: String? = "T", body: String? = "B",
                     nick: String? = "sam", created: Date, territory: String = "USA",
                     response: ASCResponse? = nil) -> ASCReview {
        ASCReview(id: id, rating: rating, title: title, body: body, reviewerNickname: nick,
                  createdDate: created, territory: territory, response: response)
    }
}
