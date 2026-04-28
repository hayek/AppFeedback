import XCTest
@testable import AppFeedback

final class NotifiedIssueStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suiteName = "NotifiedIssueStoreTests"

    override func setUp() {
        super.setUp()
        UserDefaults().removePersistentDomain(forName: suiteName)
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func test_contains_returnsFalseForUnknown() {
        let store = NotifiedIssueStore(defaults: defaults, cap: 100)
        XCTAssertFalse(store.contains("foo/bar#1"))
    }

    func test_insert_thenContains_returnsTrue() {
        let store = NotifiedIssueStore(defaults: defaults, cap: 100)
        store.insert(["foo/bar#1", "foo/bar#2"])
        XCTAssertTrue(store.contains("foo/bar#1"))
        XCTAssertTrue(store.contains("foo/bar#2"))
        XCTAssertFalse(store.contains("foo/bar#3"))
    }

    func test_insert_persistsAcrossInstances() {
        NotifiedIssueStore(defaults: defaults, cap: 100).insert(["x/y#1"])
        XCTAssertTrue(NotifiedIssueStore(defaults: defaults, cap: 100).contains("x/y#1"))
    }

    func test_insert_evictsOldestWhenOverCap() {
        let store = NotifiedIssueStore(defaults: defaults, cap: 3)
        store.insert(["a#1", "a#2", "a#3"])
        store.insert(["a#4"])
        XCTAssertFalse(store.contains("a#1"))
        XCTAssertTrue(store.contains("a#2"))
        XCTAssertTrue(store.contains("a#3"))
        XCTAssertTrue(store.contains("a#4"))
    }

    func test_snapshot_marksAllProvidedIDsAsNotified() {
        let store = NotifiedIssueStore(defaults: defaults, cap: 100)
        store.snapshot(["a#1", "a#2"])
        XCTAssertTrue(store.contains("a#1"))
        XCTAssertTrue(store.contains("a#2"))
    }
}
