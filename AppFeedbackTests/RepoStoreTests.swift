import XCTest
@testable import AppFeedback

@MainActor
final class RepoStoreTests: XCTestCase {
    private var store: RepoStore!
    private let testSuiteName = "RepoStoreTests-\(UUID())"

    override func setUp() {
        super.setUp()
        store = RepoStore(defaults: UserDefaults(suiteName: testSuiteName)!)
    }

    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: testSuiteName)
        super.tearDown()
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

    func test_persistsAcrossInstances() {
        let defaults = UserDefaults(suiteName: testSuiteName)!
        let repo = RepoConfig(displayName: "Persisted", owner: "x", repo: "y")
        store.add(repo)

        let store2 = RepoStore(defaults: defaults)
        XCTAssertEqual(store2.repos.first?.displayName, "Persisted")
    }
}
