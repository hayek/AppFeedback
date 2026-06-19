import XCTest
import SwiftData
@testable import AppFeedback

@MainActor
final class FilterPreferenceStoreTests: XCTestCase {
    private func makeStore() throws -> FilterPreferenceStore {
        let schema = Schema([RepoFilterPreference.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: config)
        return FilterPreferenceStore(context: ModelContext(container))
    }

    func test_load_emptyReturnsDefaults() throws {
        let store = try makeStore()
        let bundle = store.load(owner: "o", repo: "r")
        XCTAssertEqual(bundle, PersistedFilterBundle())
        XCTAssertEqual(bundle.task.versionScope, .any)
    }

    func test_saveThenLoad_roundTrips() throws {
        let store = try makeStore()
        var bundle = PersistedFilterBundle()
        bundle.task.versionScope = .state(.released)
        bundle.task.statuses = [.inProgress]
        bundle.version.states = [.new]
        bundle.feedback.appVersion = ["2.8"]
        bundle.feedback.appFilter = ["MyApp"]
        store.save(owner: "o", repo: "r", bundle: bundle)

        let loaded = store.load(owner: "o", repo: "r")
        XCTAssertEqual(loaded, bundle)
    }

    func test_saveThenLoad_roundTrips_unassignedScope() throws {
        let store = try makeStore()
        var bundle = PersistedFilterBundle()
        bundle.task.versionScope = .unassigned
        store.save(owner: "o", repo: "r", bundle: bundle)
        XCTAssertEqual(store.load(owner: "o", repo: "r").task.versionScope, .unassigned)
    }

    func test_isolatedByRepo() throws {
        let store = try makeStore()
        var a = PersistedFilterBundle(); a.task.versionScope = .state(.new)
        store.save(owner: "o", repo: "r1", bundle: a)
        XCTAssertEqual(store.load(owner: "o", repo: "r2"), PersistedFilterBundle())
    }

    func test_save_upsertsSingleRow() throws {
        let store = try makeStore()
        store.save(owner: "o", repo: "r", bundle: PersistedFilterBundle())
        var b = PersistedFilterBundle(); b.task.versionScope = .state(.wip)
        store.save(owner: "o", repo: "r", bundle: b)
        XCTAssertEqual(store.load(owner: "o", repo: "r").task.versionScope, .state(.wip))
    }

    func test_taskFiltersMapping_dropsSearch() {
        var live = TaskFilters()
        live.toggleState(.released)
        live.search = "ignore me"
        let dto = live.persisted
        var restored = TaskFilters()
        restored.apply(dto)
        XCTAssertEqual(restored.versionScope, .state(.released))
        XCTAssertEqual(restored.search, "")          // search not persisted
    }

    func test_feedback_sources_default_to_all_when_absent() throws {
        // A bundle encoded WITHOUT the sources field (legacy JSON) must decode to all-on.
        let legacyJSON = #"{"appVersion":[],"device":[],"osVersion":[],"issueType":[],"appFilter":[]}"#
        let data = legacyJSON.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(PersistedFeedbackFilters.self, from: data)
        XCTAssertEqual(decoded.sources, Set(FeedbackSource.allCases))
    }

    func test_default_feedback_filters_have_all_sources() {
        XCTAssertEqual(PersistedFeedbackFilters().sources, Set(FeedbackSource.allCases))
    }

    func test_sources_roundtrip_through_codable() throws {
        var f = PersistedFeedbackFilters()
        f.sources = [.appStore]
        let data = try JSONEncoder().encode(f)
        let back = try JSONDecoder().decode(PersistedFeedbackFilters.self, from: data)
        XCTAssertEqual(back.sources, [.appStore])
    }
}
