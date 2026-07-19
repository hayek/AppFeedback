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
}
