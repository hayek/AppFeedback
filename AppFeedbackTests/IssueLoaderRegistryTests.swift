import XCTest
@testable import AppFeedback

@MainActor
final class IssueLoaderRegistryTests: XCTestCase {
    private static let epoch = Date(timeIntervalSince1970: 1_750_000_000)

    override func setUp() {
        super.setUp()
        // Shared mock-protocol state: with no handler every request fails fast, which is
        // what these tests rely on (loaders land in .failed, never .loaded).
        MockURLProtocol.requestHandler = nil
    }

    private func makeConfig(_ repo: String = "r1", id: UUID = UUID()) -> ProductConfig {
        ProductConfig(id: id, displayName: repo, owner: "o", repo: repo)
    }

    private func makeIssue(_ number: Int) -> FeedbackIssue {
        FeedbackIssue(number: number, title: "Issue \(number)", createdAt: Self.epoch,
                      rawBody: "", appName: nil, appVersion: nil, device: nil, osVersion: nil,
                      email: nil, description: "d", labels: [])
    }

    private func makeRegistry(
        tokenProvider: @escaping @Sendable (ProductConfig) async -> String? = { _ in nil },
        clock: @escaping () -> Date = { IssueLoaderRegistryTests.epoch }
    ) -> IssueLoaderRegistry {
        IssueLoaderRegistry(factory: { IssueLoader(config: $0, session: .mock) },
                            tokenProvider: tokenProvider, clock: clock)
    }

    // MARK: syncWithProducts

    func testSyncCreatesLoadersAndKeepsExistingIdentity() {
        let registry = makeRegistry()
        let a = makeConfig("a"); let b = makeConfig("b")
        registry.syncWithProducts([a])
        let loaderA = registry.loaders[a.id]
        XCTAssertNotNil(loaderA)
        registry.syncWithProducts([a, b])
        XCTAssertTrue(registry.loaders[a.id] === loaderA, "existing loader identity preserved")
        XCTAssertEqual(registry.loaders.count, 2)
    }

    func testSyncRemovesLoadersForDeletedProducts() {
        let registry = makeRegistry()
        let a = makeConfig("a"); let b = makeConfig("b")
        registry.syncWithProducts([a, b])
        registry.syncWithProducts([b])
        XCTAssertNil(registry.loaders[a.id])
        XCTAssertNotNil(registry.loaders[b.id])
    }

    func testSyncDispatchesInitialLoadForNewProductsOnly() async {
        let a = makeConfig("a")
        let exp = expectation(description: "token requested for newly-added repo")
        exp.assertForOverFulfill = false
        let registry = makeRegistry(tokenProvider: { repo in
            if repo.id == a.id { exp.fulfill() }
            return nil
        })
        registry.syncWithProducts([a])
        await fulfillment(of: [exp], timeout: 2)
    }

    // MARK: loadedGroups

    func testLoadedGroupsIncludesOnlyLoadedLoaders() {
        let registry = makeRegistry()
        let a = makeConfig("a"); let b = makeConfig("b")
        registry.syncWithProducts([a, b])
        registry.loaders[a.id]?.state = .loaded([makeIssue(1)], Self.epoch)
        // b stays .idle
        let groups = registry.loadedGroups
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].owner, "o")
        XCTAssertEqual(groups[0].repo, "a")
        XCTAssertEqual(groups[0].issues.map(\.number), [1])
    }

    // MARK: refreshTick cadence (zero products — no loads dispatched, stamps still testable)

    func testFirstTickSweepsFullyThenDaily() async {
        var now = Self.epoch
        let registry = makeRegistry(clock: { now })
        await registry.refreshTick()
        XCTAssertEqual(registry.lastFullReconcileAt, Self.epoch, "first tick is a full sweep")

        now = Self.epoch.addingTimeInterval(IssueLoaderRegistry.pollInterval)
        await registry.refreshTick()
        XCTAssertEqual(registry.lastFullReconcileAt, Self.epoch, "within 24h stays incremental")

        now = Self.epoch.addingTimeInterval(IssueLoaderRegistry.fullReconcileInterval)
        await registry.refreshTick()
        XCTAssertEqual(registry.lastFullReconcileAt, now, "24h later sweeps again")
    }

    func testPollIfStaleRefreshesOnlyWhenOlderThanInterval() async {
        var now = Self.epoch
        let registry = makeRegistry(clock: { now })
        await registry.refreshTick()
        XCTAssertEqual(registry.lastRefreshAt, Self.epoch)

        now = Self.epoch.addingTimeInterval(5 * 60)
        await registry.pollIfStale()
        XCTAssertEqual(registry.lastRefreshAt, Self.epoch, "fresh → no-op")

        now = Self.epoch.addingTimeInterval(IssueLoaderRegistry.pollInterval)
        await registry.pollIfStale()
        XCTAssertEqual(registry.lastRefreshAt, now, "stale → refreshed")
    }

    func testPollIfStaleWithNoPriorRefreshRefreshes() async {
        let registry = makeRegistry()
        await registry.pollIfStale()
        XCTAssertNotNil(registry.lastRefreshAt)
    }

    // MARK: retryStuck / single-product load

    func testRetryStuckReloadsIdleAndFailedButNotLoaded() async throws {
        let idle = makeConfig("idle"); let failed = makeConfig("failed"); let loaded = makeConfig("loaded")
        let recorder = TokenRequestRecorder()
        let registry = makeRegistry(tokenProvider: { repo in
            await recorder.record(repo.id)
            return "tok"   // non-nil → loader.load runs against the mock session and fails fast
        })
        registry.syncWithProducts([idle, failed, loaded])

        // Wait for the initial-load dispatch to settle: all loaders leave .idle via the
        // mock session (→ .failed).
        try await waitUntil { registry.loaders.values.allSatisfy { if case .failed = $0.state { return true }; return false } }

        registry.loaders[idle.id]?.state = .idle
        registry.loaders[loaded.id]?.state = .loaded([], Self.epoch)
        // failed's loader stays .failed
        await recorder.startRecording()

        registry.retryStuck()
        try await waitUntil { await recorder.recorded.count >= 2 }
        try? await Task.sleep(for: .milliseconds(50))   // settle window for a spurious third load
        let recorded = await recorder.recorded
        XCTAssertTrue(recorded.contains(idle.id))
        XCTAssertTrue(recorded.contains(failed.id))
        XCTAssertFalse(recorded.contains(loaded.id), "a loaded repo must not be re-fetched")
    }

    func testLoadProductIDLoadsOnlyThatProduct() async throws {
        let a = makeConfig("a"); let b = makeConfig("b")
        let recorder = TokenRequestRecorder()
        let registry = makeRegistry(tokenProvider: { repo in
            await recorder.record(repo.id)
            return "tok"
        })
        registry.syncWithProducts([a, b])
        // Recorder is off during the initial-load dispatch, so settle on loader state instead.
        try await waitUntil { registry.loaders.values.allSatisfy { if case .failed = $0.state { return true }; return false } }
        await recorder.startRecording()

        await registry.load(productID: a.id)
        let recorded = await recorder.recorded
        XCTAssertEqual(recorded, [a.id])
    }

    // MARK: triageSink

    func testRefreshTickInvokesTriageSinkWithLoadedGroups() async {
        let registry = makeRegistry()
        let a = makeConfig("a")
        registry.syncWithProducts([a])
        registry.loaders[a.id]?.state = .loaded([makeIssue(1)], Self.epoch)

        var received: [(repo: ProductConfig, issues: [FeedbackIssue])] = []
        registry.triageSink = { groups in received = groups }
        await registry.refreshTick()

        XCTAssertEqual(received.map(\.repo.repo), ["a"])
        XCTAssertEqual(received.first?.issues.map(\.number), [1])
    }

    /// Polls `condition` every 10ms until true or ~2s elapse.
    private func waitUntil(_ condition: @MainActor () async -> Bool) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("condition not met within timeout")
    }
}

/// Records tokenProvider calls, but only after `startRecording()` — lets tests ignore the
/// initial-load dispatch from syncWithProducts.
private actor TokenRequestRecorder {
    private(set) var recorded: [UUID] = []
    private var recording = false
    func startRecording() { recorded = []; recording = true }
    func record(_ id: UUID) { if recording { recorded.append(id) } }
}
