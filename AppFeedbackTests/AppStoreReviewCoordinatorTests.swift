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

@MainActor
final class AppStoreReviewCoordinatorRegistryTests: XCTestCase {
    private func makeStore() throws -> AppStoreReviewMirrorStore {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(for: AppStoreReviewMirror.self, configurations: config)
        return AppStoreReviewMirrorStore(context: ModelContext(container))
    }
    private func cfg(_ id: UUID, app: String) -> ASCProductConfig {
        ASCProductConfig(id: id, owner: "o", repo: "r", issuerID: "i", keyID: "k", appAppleID: app)
    }

    func testSyncSpinsUpAndTearsDownByProduct() throws {
        let store = try makeStore()
        let registry = AppStoreReviewCoordinatorRegistry { cfg in
            AppStoreReviewCoordinator(
                config: cfg, client: FakeAppStoreConnectClient(), issueWriter: FakeIssueWriting(),
                commentPoster: GitHubCommentPoster(session: .mock), mirrorStore: store,
                tokenLoader: { "tok" }, activityLog: nil, clock: { Date() })
        }
        let a = UUID(); let b = UUID()
        registry.syncWithProducts([cfg(a, app: "1"), cfg(b, app: "2")])
        XCTAssertEqual(registry.coordinatorCount, 2)
        registry.syncWithProducts([cfg(a, app: "1")])     // b removed
        XCTAssertEqual(registry.coordinatorCount, 1)
        registry.syncWithProducts([])                     // all removed
        XCTAssertEqual(registry.coordinatorCount, 0)
    }

    func testSyncIsIdempotent() throws {
        let store = try makeStore()
        var built = 0
        let registry = AppStoreReviewCoordinatorRegistry { cfg in
            built += 1
            return AppStoreReviewCoordinator(
                config: cfg, client: FakeAppStoreConnectClient(), issueWriter: FakeIssueWriting(),
                commentPoster: GitHubCommentPoster(session: .mock), mirrorStore: store,
                tokenLoader: { "tok" }, activityLog: nil, clock: { Date() })
        }
        let a = UUID()
        registry.syncWithProducts([cfg(a, app: "1")])
        registry.syncWithProducts([cfg(a, app: "1")])
        XCTAssertEqual(built, 1, "same product not rebuilt")
        XCTAssertEqual(registry.coordinatorCount, 1)
    }

    // [responderContext] The seam Phase 4 consumes.
    func testResponderContextReflectsClientAndSink() async throws {
        let store = try makeStore()
        let client = FakeAppStoreConnectClient()
        let registry = AppStoreReviewCoordinatorRegistry { c in
            AppStoreReviewCoordinator(
                config: c, client: client, issueWriter: FakeIssueWriting(),
                commentPoster: GitHubCommentPoster(session: .mock), mirrorStore: store,
                tokenLoader: { "tok" }, activityLog: nil, clock: { Date() })
        }
        let a = UUID()
        registry.syncWithProducts([ASCProductConfig(id: a, owner: "acme", repo: "app",
                                                    issuerID: "i", keyID: "k", appAppleID: "1")])
        let ctx = await registry.responderContext(productID: a)
        XCTAssertNotNil(ctx)
        XCTAssertEqual(ctx?.owner, "acme")
        XCTAssertEqual(ctx?.repo, "app")
        XCTAssertEqual(ctx?.isReadOnly, false, "read-only flips only after a 403 write")
        let unknownCtx = await registry.responderContext(productID: UUID())
        XCTAssertNil(unknownCtx, "unknown product ⇒ nil")
    }

    func testResponderContextIsReadOnlyAfter403() async throws {
        let store = try makeStore()
        let registry = AppStoreReviewCoordinatorRegistry { c in
            AppStoreReviewCoordinator(
                config: c, client: FakeAppStoreConnectClient(), issueWriter: FakeIssueWriting(),
                commentPoster: GitHubCommentPoster(session: .mock), mirrorStore: store,
                tokenLoader: { "tok" }, activityLog: nil, clock: { Date() })
        }
        let a = UUID()
        registry.syncWithProducts([ASCProductConfig(id: a, owner: "o", repo: "r",
                                                    issuerID: "i", keyID: "k", appAppleID: "1")])
        // Simulate Phase 4 observing a 403 on a write and flipping the coordinator read-only.
        await registry.coordinator(for: a)?.markReadOnly()
        let ctx = await registry.responderContext(productID: a)
        XCTAssertEqual(ctx?.isReadOnly, true)
    }

    // [race-window fix] markReadOnly records the flag synchronously on the MainActor registry
    // before dispatching to the coordinator actor. A concurrent responderContext call must see
    // isReadOnly: true immediately, even if the coordinator Task hasn't run yet.
    func testMarkReadOnlyIsVisibleSynchronouslyOnRegistry() async throws {
        let store = try makeStore()
        let registry = AppStoreReviewCoordinatorRegistry { c in
            AppStoreReviewCoordinator(
                config: c, client: FakeAppStoreConnectClient(), issueWriter: FakeIssueWriting(),
                commentPoster: GitHubCommentPoster(session: .mock), mirrorStore: store,
                tokenLoader: { "tok" }, activityLog: nil, clock: { Date() })
        }
        let a = UUID()
        registry.syncWithProducts([ASCProductConfig(id: a, owner: "o", repo: "r",
                                                    issuerID: "i", keyID: "k", appAppleID: "1")])
        // Call markReadOnly via the registry (not the coordinator directly) — this is the path
        // Phase 4 uses via the onReadOnly callback. The flag must be recorded immediately, before
        // any Task yields, so responderContext called right after returns isReadOnly: true.
        registry.markReadOnly(productID: a)
        let ctx = await registry.responderContext(productID: a)
        XCTAssertEqual(ctx?.isReadOnly, true,
                       "registry-level readOnlyProductIDs closes the race window")
    }

    // restart() clears the read-only flag so a replacement coordinator starts writable.
    func testRestartClearsReadOnlyFlag() async throws {
        let store = try makeStore()
        let registry = AppStoreReviewCoordinatorRegistry { c in
            AppStoreReviewCoordinator(
                config: c, client: FakeAppStoreConnectClient(), issueWriter: FakeIssueWriting(),
                commentPoster: GitHubCommentPoster(session: .mock), mirrorStore: store,
                tokenLoader: { "tok" }, activityLog: nil, clock: { Date() })
        }
        let a = UUID()
        let productCfg = ASCProductConfig(id: a, owner: "o", repo: "r",
                                          issuerID: "i", keyID: "k", appAppleID: "1")
        registry.syncWithProducts([productCfg])
        registry.markReadOnly(productID: a)
        // Verify it is read-only before restart.
        var ctx = await registry.responderContext(productID: a)
        XCTAssertEqual(ctx?.isReadOnly, true)
        // Restart simulates a credential change — flag must be cleared so new controller is writable.
        registry.restart(productID: a, configs: [productCfg])
        ctx = await registry.responderContext(productID: a)
        XCTAssertEqual(ctx?.isReadOnly, false, "restart clears the read-only flag on the registry")
    }
}
