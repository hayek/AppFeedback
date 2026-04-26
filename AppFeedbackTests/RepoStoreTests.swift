import XCTest
import SwiftData
@testable import AppFeedback

@MainActor
final class RepoStoreTests: XCTestCase {
    private var container: ModelContainer!
    private var store: RepoStore!

    override func setUp() async throws {
        try await super.setUp()
        let schema = Schema([Repo.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        container = try ModelContainer(for: schema, configurations: config)
        store = RepoStore(context: ModelContext(container))
    }

    override func tearDown() async throws {
        store = nil
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

    func test_remove_deletesRepo() {
        let repo = RepoConfig(displayName: "Test", owner: "org", repo: "feedback")
        store.add(repo)
        store.remove(id: repo.id)
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
}
