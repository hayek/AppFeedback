import XCTest
import SwiftData
@testable import AppFeedback

@MainActor
final class AppStoreReviewCoordinatorTests: XCTestCase {
    private func makeStore() throws -> AppStoreReviewMirrorStore {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: AppStoreReviewMirror.self, configurations: config)
        return AppStoreReviewMirrorStore(context: ModelContext(container))
    }
    private func config(_ pid: UUID = UUID()) -> ASCProductConfig {
        ASCProductConfig(id: pid, owner: "o", repo: "r", issuerID: "i", keyID: "k", appAppleID: "123")
    }
    private func makeCoordinator(_ cfg: ASCProductConfig, client: FakeAppStoreConnectClient,
                                 writer: FakeIssueWriting, store: AppStoreReviewMirrorStore,
                                 clock: @escaping @Sendable () -> Date = { Date() }) -> AppStoreReviewCoordinator {
        AppStoreReviewCoordinator(
            config: cfg, client: client, issueWriter: writer, commentPoster: GitHubCommentPoster(session: .mock),
            mirrorStore: store, tokenLoader: { "tok" }, activityLog: nil, clock: clock)
    }

    func testNewReviewCreatesIssueAndRecordsMirror() async throws {
        let cfg = config(); let client = FakeAppStoreConnectClient(); let writer = FakeIssueWriting(startingNumber: 500)
        let store = try makeStore()
        client.setPages([ASCReviewPage(reviews: [
            .make(id: "R1", rating: 5, title: "Great", body: "Love", created: Date(timeIntervalSince1970: 1_700_000_000))
        ], nextCursor: nil, rateRemaining: 3000)])
        let coord = makeCoordinator(cfg, client: client, writer: writer, store: store)
        try await coord.poll()
        let creates = await writer.creates
        XCTAssertEqual(creates.count, 1)
        XCTAssertEqual(creates[0].title, "Great")
        XCTAssertTrue(creates[0].labels.contains("source:app-store"))
        XCTAssertTrue(creates[0].labels.contains("rating:5"))
        XCTAssertEqual(store.mirror(reviewId: "R1")?.issueNumber, 500)
    }

    func testKnownReviewIsNotRecreated() async throws {
        let cfg = config(); let client = FakeAppStoreConnectClient(); let writer = FakeIssueWriting(startingNumber: 500)
        let store = try makeStore()
        let r = ASCReview.make(id: "R1", rating: 5, title: "Great", body: "Love", created: Date(timeIntervalSince1970: 1_700_000_000))
        _ = store.upsert(reviewId: "R1", productID: cfg.id, issueNumber: 9,
                         contentHash: AppStoreReviewSynthesizer.contentHash(for: r))
        client.setPages([ASCReviewPage(reviews: [r], nextCursor: nil, rateRemaining: nil)])
        let coord = makeCoordinator(cfg, client: client, writer: writer, store: store)
        try await coord.poll()
        let creates = await writer.creates
        XCTAssertTrue(creates.isEmpty, "an unchanged known review is skipped")
    }

    func testIncrementalStopsAtFirstKnownReview() async throws {
        // Page1 has a NEW review then a KNOWN one; incremental must stop without fetching page2.
        let cfg = config(); let client = FakeAppStoreConnectClient(); let writer = FakeIssueWriting()
        let store = try makeStore()
        let known = ASCReview.make(id: "OLD", created: Date(timeIntervalSince1970: 1_600_000_000))
        _ = store.upsert(reviewId: "OLD", productID: cfg.id, issueNumber: 1,
                         contentHash: AppStoreReviewSynthesizer.contentHash(for: known))
        client.setPages([
            ASCReviewPage(reviews: [.make(id: "NEW", created: Date(timeIntervalSince1970: 1_700_000_000)), known],
                          nextCursor: "PAGE2", rateRemaining: nil),
            ASCReviewPage(reviews: [.make(id: "SHOULD_NOT_FETCH", created: Date(timeIntervalSince1970: 1_500_000_000))],
                          nextCursor: nil, rateRemaining: nil),
        ])
        let coord = makeCoordinator(cfg, client: client, writer: writer, store: store)
        try await coord.poll()
        let creates = await writer.creates
        XCTAssertEqual(creates.map(\.title).count, 1, "only NEW synthesized; page2 not walked")
        XCTAssertNil(store.mirror(reviewId: "SHOULD_NOT_FETCH"))
    }

    func testEditedReviewUpdatesIssueOnFullRescan() async throws {
        let cfg = config(); let client = FakeAppStoreConnectClient(); let writer = FakeIssueWriting()
        let store = try makeStore()
        let original = ASCReview.make(id: "R1", rating: 5, title: "Old", body: "old body", created: Date(timeIntervalSince1970: 1_700_000_000))
        _ = store.upsert(reviewId: "R1", productID: cfg.id, issueNumber: 77,
                         contentHash: AppStoreReviewSynthesizer.contentHash(for: original))
        let edited = ASCReview.make(id: "R1", rating: 5, title: "New", body: "new body", created: original.createdDate)
        client.setPages([ASCReviewPage(reviews: [edited], nextCursor: nil, rateRemaining: nil)])
        let coord = makeCoordinator(cfg, client: client, writer: writer, store: store)
        try await coord.fullRescan()
        let updates = await writer.updates
        XCTAssertEqual(updates.count, 1)
        XCTAssertEqual(updates[0].number, 77)
        XCTAssertEqual(updates[0].title, "New")
        XCTAssertTrue(updates[0].body?.contains("Review edited") == true)
        XCTAssertEqual(store.mirror(reviewId: "R1")?.contentHash,
                       AppStoreReviewSynthesizer.contentHash(for: edited))
    }

    func testDeletedReviewClosesIssueWithLabel() async throws {
        let cfg = config(); let client = FakeAppStoreConnectClient(); let writer = FakeIssueWriting()
        let store = try makeStore()
        let gone = ASCReview.make(id: "GONE", created: Date(timeIntervalSince1970: 1_700_000_000))
        _ = store.upsert(reviewId: "GONE", productID: cfg.id, issueNumber: 88,
                         contentHash: AppStoreReviewSynthesizer.contentHash(for: gone))
        // Full re-scan returns NO reviews ⇒ "GONE" is absent ⇒ treated as deleted.
        client.setPages([ASCReviewPage(reviews: [], nextCursor: nil, rateRemaining: nil)])
        let coord = makeCoordinator(cfg, client: client, writer: writer, store: store)
        try await coord.fullRescan()
        let updates = await writer.updates
        XCTAssertEqual(updates.count, 1)
        XCTAssertEqual(updates[0].number, 88)
        XCTAssertEqual(updates[0].state, "closed")
        XCTAssertEqual(updates[0].labels?.contains(AppStoreReviewSynthesizer.reviewDeletedLabel), true)
    }

    func testRateLimitedErrorPropagates() async throws {
        let cfg = config(); let client = FakeAppStoreConnectClient(); let writer = FakeIssueWriting()
        let store = try makeStore()
        client.setThrowOnList(AppStoreConnectError.rateLimited)
        let coord = makeCoordinator(cfg, client: client, writer: writer, store: store)
        do { try await coord.poll(); XCTFail("expected throw") }
        catch let e as AppStoreConnectError { if case .rateLimited = e {} else { XCTFail("wrong error \(e)") } }
    }

    func testBackoffClampedToBase() {
        XCTAssertEqual(AppStoreReviewCoordinator.backoffSeconds(baseSeconds: 900, consecutiveFailures: 0), 900)
        XCTAssertEqual(AppStoreReviewCoordinator.backoffSeconds(baseSeconds: 900, consecutiveFailures: 100), 900)
        XCTAssertEqual(AppStoreReviewCoordinator.backoffSeconds(baseSeconds: 900, consecutiveFailures: 1), 30)
    }

    // [F] Per-source status surfaces on the coordinator.
    func testStatusRecordsSuccessThenError() async throws {
        let cfg = config(); let client = FakeAppStoreConnectClient(); let writer = FakeIssueWriting()
        let store = try makeStore()
        client.setPages([ASCReviewPage(reviews: [], nextCursor: nil, rateRemaining: nil)])
        let fixed = Date(timeIntervalSince1970: 1_700_000_000)
        let coord = makeCoordinator(cfg, client: client, writer: writer, store: store, clock: { fixed })
        await coord.pollNow()
        var status = await coord.status()
        XCTAssertEqual(status.lastSuccessAt, fixed, "a successful poll stamps lastSuccessAt")
        XCTAssertNil(status.lastError)
        // Now force a failure and confirm lastError is recorded (lastSuccessAt is preserved).
        client.setThrowOnList(AppStoreConnectError.rateLimited)
        await coord.pollNow()
        status = await coord.status()
        XCTAssertEqual(status.lastSuccessAt, fixed)
        XCTAssertNotNil(status.lastError)
    }

    // [G] Deletion close preserves the rating badge: the body is NOT rewritten (markers survive),
    // so IssueLoader.resolveRating still yields the rating after the close.
    func testDeletionPreservesRatingMarkerForResolveRating() async throws {
        let cfg = config(); let client = FakeAppStoreConnectClient(); let writer = FakeIssueWriting()
        let store = try makeStore()
        let r = ASCReview.make(id: "R1", rating: 3, title: "T", body: "B",
                               created: Date(timeIntervalSince1970: 1_700_000_000))
        let originalBody = AppStoreReviewSynthesizer.body(for: r)
        _ = store.upsert(reviewId: "R1", productID: cfg.id, issueNumber: 55,
                         contentHash: AppStoreReviewSynthesizer.contentHash(for: r))
        client.setPages([ASCReviewPage(reviews: [], nextCursor: nil, rateRemaining: nil)])  // R1 absent ⇒ deleted
        let coord = makeCoordinator(cfg, client: client, writer: writer, store: store)
        try await coord.fullRescan()
        let updates = await writer.updates
        XCTAssertEqual(updates.count, 1)
        XCTAssertEqual(updates[0].state, "closed")
        // The deletion update must NOT rewrite the body (nil body ⇒ markers preserved on GitHub).
        XCTAssertNil(updates[0].body, "deletion must not rewrite the body so rating: marker survives")
        // resolveRating reads the (still-present) rating marker → badge survives even though the
        // labels now only carry source:app-store + review-deleted.
        let parsedRating = 3  // the rating marker value still present in the unchanged body
        XCTAssertEqual(IssueLoader.resolveRating(markerRating: parsedRating,
                                                 labels: ["source:app-store",
                                                          AppStoreReviewSynthesizer.reviewDeletedLabel]), 3)
        XCTAssertTrue(originalBody.contains("rating: 3"), "sanity: original body carried the rating marker")
    }

    // [D-reconcile] Cross-device dupes: two mirror rows for the SAME reviewId (issues 42 & 43).
    // Reconcile keeps the LOWEST (42), closes & deletes 43; never deletes the kept row.
    func testReconcileKeepsLowestIssueClosesAndDeletesHigher() async throws {
        let cfg = config(); let client = FakeAppStoreConnectClient(); let writer = FakeIssueWriting()
        let store = try makeStore()
        _ = store.upsert(reviewId: "DUP", productID: cfg.id, issueNumber: 42, contentHash: "h")
        store.insertRawForTest(reviewId: "DUP", productID: cfg.id, issueNumber: 43, contentHash: "h")
        XCTAssertEqual(store.allFor(productID: cfg.id).count, 2)
        let coord = makeCoordinator(cfg, client: client, writer: writer, store: store)
        await coord.reconcileDuplicatesForTest(reviewId: "DUP")
        // 43 closed via the issue writer.
        let updates = await writer.updates
        XCTAssertEqual(updates.count, 1)
        XCTAssertEqual(updates[0].number, 43)
        XCTAssertEqual(updates[0].state, "closed")
        // 43 deleted from the mirror; 42 (kept) remains.
        let rows = store.allFor(productID: cfg.id)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.issueNumber, 42)
        XCTAssertNotNil(store.mirror(reviewId: "DUP"))
    }
}
