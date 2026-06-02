import XCTest
import SwiftData
@testable import AppFeedback

@MainActor
final class RepoStoreTests: XCTestCase {
    private var container: ModelContainer!
    private var store: RepoStore!
    private var sharedContext: ModelContext!

    override func setUp() async throws {
        try await super.setUp()
        let schema = Schema([Repo.self, HiddenApp.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        container = try ModelContainer(for: schema, configurations: config)
        let ctx = ModelContext(container)
        sharedContext = ctx
        let hidden = HiddenAppStore(context: ctx)
        store = RepoStore(context: ctx, hiddenAppStore: hidden)
    }

    override func tearDown() async throws {
        store = nil
        sharedContext = nil
        container = nil
        try await super.tearDown()
    }

    func test_initiallyEmpty() {
        XCTAssertTrue(store.repos.isEmpty)
    }

    func test_add_appendsRepo() {
        let repo = RepoConfig(displayName: "Test", owner: "org", repo: "feedback")
        store.add(repo)
        XCTAssertEqual(store.repos.count, 1)
        XCTAssertEqual(store.repos.first?.owner, "org")
    }

    func test_remove_deletesRepo() async {
        let repo = RepoConfig(displayName: "Test", owner: "org", repo: "feedback")
        store.add(repo)
        await store.remove(id: repo.id)
        XCTAssertTrue(store.repos.isEmpty)
    }

    func test_update_replacesRepo() {
        var repo = RepoConfig(displayName: "Old", owner: "org", repo: "feedback")
        store.add(repo)
        repo.displayName = "New"
        store.update(repo)
        XCTAssertEqual(store.repos.first?.displayName, "New")
    }

    func test_hideApp_recordsName() {
        let repo = RepoConfig(displayName: "T", owner: "o", repo: "r")
        store.add(repo)
        store.hideApp("AppA", in: repo.id)
        XCTAssertEqual(store.hiddenAppsFor(repo.id), ["AppA"])
    }

    func test_unhideAllApps_clearsNames() {
        let repo = RepoConfig(displayName: "T", owner: "o", repo: "r")
        store.add(repo)
        store.hideApp("AppA", in: repo.id)
        store.hideApp("AppB", in: repo.id)
        store.unhideAllApps(in: repo.id)
        XCTAssertTrue(store.hiddenAppsFor(repo.id).isEmpty)
    }

    func test_persistsAcrossInstances() {
        let repo = RepoConfig(displayName: "Persisted", owner: "x", repo: "y")
        store.add(repo)

        let store2 = RepoStore(context: ModelContext(container))
        XCTAssertEqual(store2.repos.first?.displayName, "Persisted")
    }

    func test_setColor_storesAndReadsHex() {
        let repo = RepoConfig(displayName: "T", owner: "o", repo: "r")
        store.add(repo)
        store.setColor("4ef8d0", forApp: "AppA", in: repo.id)
        XCTAssertEqual(store.colorHexFor(app: "AppA", in: repo.id), "4ef8d0")
        XCTAssertNil(store.colorHexFor(app: "AppB", in: repo.id))
    }

    func test_setColor_persistsAcrossInstances() {
        let repo = RepoConfig(displayName: "T", owner: "o", repo: "r")
        store.add(repo)
        store.setColor("ff6b8a", forApp: "AppA", in: repo.id)

        let store2 = RepoStore(context: ModelContext(container))
        XCTAssertEqual(store2.colorHexFor(app: "AppA", in: repo.id), "ff6b8a")
    }

    func test_repoColor_defaultsToNil() {
        let repo = RepoConfig(displayName: "T", owner: "o", repo: "r")
        store.add(repo)
        XCTAssertNil(store.colorHexFor(repo: repo.id))
    }

    func test_setRepoColor_storesAndReadsHex() {
        let repo = RepoConfig(displayName: "T", owner: "o", repo: "r")
        store.add(repo)
        store.setColor("7b8cff", forRepo: repo.id)
        XCTAssertEqual(store.colorHexFor(repo: repo.id), "7b8cff")
    }

    func test_setRepoColor_nilClearsOverride() {
        let repo = RepoConfig(displayName: "T", owner: "o", repo: "r")
        store.add(repo)
        store.setColor("7b8cff", forRepo: repo.id)
        store.setColor(nil, forRepo: repo.id)
        XCTAssertNil(store.colorHexFor(repo: repo.id))
    }

    func test_setRepoColor_persistsAcrossInstances() {
        let repo = RepoConfig(displayName: "T", owner: "o", repo: "r")
        store.add(repo)
        store.setColor("34d399", forRepo: repo.id)

        let store2 = RepoStore(context: ModelContext(container))
        XCTAssertEqual(store2.colorHexFor(repo: repo.id), "34d399")
    }

    func test_hideApp_writesToHiddenAppStore() throws {
        let repo = RepoConfig(displayName: "T", owner: "o", repo: "r")
        store.add(repo)
        store.hideApp("AppA", in: repo.id)
        let rows = try sharedContext.fetch(FetchDescriptor<HiddenApp>())
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.appName, "AppA")
        XCTAssertEqual(rows.first?.repoOwner, "o")
        XCTAssertEqual(rows.first?.repoName, "r")
    }

    func testConnectedRepoRoundTrips() throws {
        var cfg = RepoConfig(displayName: "P", owner: "o", repo: "r")
        cfg.connectedRepoOwner = "o2"; cfg.connectedRepoName = "code"
        store.add(cfg)
        let reloaded = store.repos.first { $0.owner == "o" }
        XCTAssertEqual(reloaded?.connectedRepoOwner, "o2")
        XCTAssertEqual(reloaded?.connectedRepoName, "code")
    }
}
