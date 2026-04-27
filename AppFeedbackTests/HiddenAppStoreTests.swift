import XCTest
import SwiftData
@testable import AppFeedback

@MainActor
final class HiddenAppStoreTests: XCTestCase {
    private func makeStore() throws -> (HiddenAppStore, ModelContext) {
        let schema = Schema([HiddenApp.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: config)
        let ctx = ModelContext(container)
        return (HiddenAppStore(context: ctx), ctx)
    }

    func test_hiddenApps_isEmptyInitially() throws {
        let (store, _) = try makeStore()
        XCTAssertTrue(store.hiddenApps(owner: "o", repo: "r").isEmpty)
    }

    func test_hide_persistsAndIsIdempotent() throws {
        let (store, ctx) = try makeStore()
        store.hide(owner: "o", repo: "r", appName: "Foo")
        store.hide(owner: "o", repo: "r", appName: "Foo")
        let rows = try ctx.fetch(FetchDescriptor<HiddenApp>())
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(store.hiddenApps(owner: "o", repo: "r"), ["Foo"])
    }

    func test_unhideAll_removesOnlyMatching() throws {
        let (store, ctx) = try makeStore()
        store.hide(owner: "o", repo: "r1", appName: "A")
        store.hide(owner: "o", repo: "r1", appName: "B")
        store.hide(owner: "o", repo: "r2", appName: "C")
        store.unhideAll(owner: "o", repo: "r1")
        let rows = try ctx.fetch(FetchDescriptor<HiddenApp>())
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.appName, "C")
    }

    func test_isolatedByRepo() throws {
        let (store, _) = try makeStore()
        store.hide(owner: "o", repo: "r1", appName: "A")
        store.hide(owner: "o", repo: "r2", appName: "B")
        XCTAssertEqual(store.hiddenApps(owner: "o", repo: "r1"), ["A"])
        XCTAssertEqual(store.hiddenApps(owner: "o", repo: "r2"), ["B"])
    }

    func test_migrateLegacy_insertsMissingOnly() throws {
        let (store, ctx) = try makeStore()
        store.hide(owner: "o", repo: "r", appName: "Existing")
        store.migrateLegacy(owner: "o", repo: "r", legacyNames: ["Existing", "New1", "New2"])
        let rows = try ctx.fetch(FetchDescriptor<HiddenApp>())
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(store.hiddenApps(owner: "o", repo: "r"), ["Existing", "New1", "New2"])
    }
}
