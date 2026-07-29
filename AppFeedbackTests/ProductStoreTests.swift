import XCTest
import SwiftData
@testable import AppFeedback

@MainActor
final class ProductStoreTests: XCTestCase {
    private var harness: ProductStoreTestHarness!
    private var store: ProductStore { harness.store }

    override func setUp() async throws {
        try await super.setUp()
        harness = try ProductStoreTestHarness()
    }

    override func tearDown() async throws {
        harness = nil
        try await super.tearDown()
    }

    func test_initiallyEmpty() { XCTAssertTrue(store.repos.isEmpty) }

    func test_products_mirrorsRepos() {
        store.add(ProductConfig(displayName: "Test", owner: "org", repo: "feedback"))
        XCTAssertEqual(store.products, store.repos)
    }

    func test_harnessSeed_setsFeedbackInboxAccountID() {
        let inboxID = UUID()
        harness.seed(owner: "octo", repo: "feedback",
                     redactEmailAddresses: true, feedbackInboxAccountID: inboxID)
        XCTAssertEqual(store.products.first?.feedbackInboxAccountID, inboxID)
    }

    func test_add_appendsProduct() {
        store.add(ProductConfig(displayName: "Test", owner: "org", repo: "feedback"))
        XCTAssertEqual(store.repos.count, 1)
        XCTAssertEqual(store.repos.first?.owner, "org")
    }

    func test_remove_deletesProduct() async {
        let p = ProductConfig(displayName: "Test", owner: "org", repo: "feedback")
        store.add(p)
        await store.remove(id: p.id)
        XCTAssertTrue(store.repos.isEmpty)
    }

    func test_update_replacesProduct() {
        var p = ProductConfig(displayName: "Old", owner: "org", repo: "feedback")
        store.add(p)
        p.displayName = "New"
        store.update(p)
        XCTAssertEqual(store.repos.first?.displayName, "New")
    }

    func test_persistsAcrossInstances() {
        store.add(ProductConfig(displayName: "Persisted", owner: "x", repo: "y"))
        let store2 = ProductStore(context: ModelContext(harness.container))
        XCTAssertEqual(store2.repos.first?.displayName, "Persisted")
    }

    func test_setProductColor_storesAndReadsHex() {
        let p = ProductConfig(displayName: "T", owner: "o", repo: "r")
        store.add(p)
        store.setColor("7b8cff", forRepo: p.id)
        XCTAssertEqual(store.colorHexFor(repo: p.id), "7b8cff")
    }

    func test_connectedRepoRoundTrips() throws {
        var cfg = ProductConfig(displayName: "P", owner: "o", repo: "r")
        cfg.connectedRepoOwner = "o2"; cfg.connectedRepoName = "code"
        store.add(cfg)
        let reloaded = store.repos.first { $0.owner == "o" }
        XCTAssertEqual(reloaded?.connectedRepoOwner, "o2")
        XCTAssertEqual(reloaded?.connectedRepoName, "code")
    }

    func test_newSourceFields_roundTripThroughAddAndReload() {
        let inboxID = UUID()
        var cfg = ProductConfig(displayName: "P", owner: "o", repo: "r")
        cfg.appStoreIssuerID = "iss-1"
        cfg.appStoreKeyID = "key-1"
        cfg.appStoreAppAppleID = "1234567890"
        cfg.feedbackInboxAccountID = inboxID
        store.add(cfg)
        let reloaded = store.repos.first { $0.owner == "o" }
        XCTAssertEqual(reloaded?.appStoreIssuerID, "iss-1")
        XCTAssertEqual(reloaded?.appStoreKeyID, "key-1")
        XCTAssertEqual(reloaded?.appStoreAppAppleID, "1234567890")
        XCTAssertEqual(reloaded?.feedbackInboxAccountID, inboxID)
    }

    func test_newSourceFields_updateMutatesModel() {
        var cfg = ProductConfig(displayName: "P", owner: "o", repo: "r")
        store.add(cfg)
        cfg.appStoreAppAppleID = "999"
        store.update(cfg)
        let reloaded = store.repos.first { $0.owner == "o" }
        XCTAssertEqual(reloaded?.appStoreAppAppleID, "999")
    }
}
