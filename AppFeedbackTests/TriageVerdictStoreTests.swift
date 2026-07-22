import Testing
import SwiftData
@testable import AppFeedback

@MainActor
struct TriageVerdictStoreTests {
    private func makeStore() throws -> TriageVerdictStore {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: TriageVerdictRecord.self, configurations: config)
        return TriageVerdictStore(context: ModelContext(container))
    }

    @Test func upsertCreatesThenUpdates() throws {
        let store = try makeStore()
        store.upsert(owner: "o", repo: "r", number: 5) { $0.state = TriageState.pending.rawValue }
        #expect(store.hasRecord(owner: "o", repo: "r", number: 5))
        store.upsert(owner: "o", repo: "r", number: 5) { $0.state = TriageState.accepted.rawValue }
        #expect(store.record(owner: "o", repo: "r", number: 5)?.state == TriageState.accepted.rawValue)
        // Still exactly one record.
        #expect(store.pendingSuggestions(owner: "o", repo: "r").isEmpty)
    }

    @Test func pendingSuggestionsFiltersByStateAndRepo() throws {
        let store = try makeStore()
        store.upsert(owner: "o", repo: "r", number: 1) { $0.state = TriageState.pending.rawValue }
        store.upsert(owner: "o", repo: "r", number: 2) { $0.state = TriageState.notActionable.rawValue }
        store.upsert(owner: "o", repo: "other", number: 3) { $0.state = TriageState.pending.rawValue }
        let pending = store.pendingSuggestions(owner: "o", repo: "r")
        #expect(pending.map(\.feedbackNumber) == [1])
    }

    @Test func snapshotPreexistingOnlyInsertsMissing() throws {
        let store = try makeStore()
        store.upsert(owner: "o", repo: "r", number: 1) { $0.state = TriageState.pending.rawValue }
        store.snapshotPreexisting(owner: "o", repo: "r", numbers: [1, 2, 3])
        #expect(store.record(owner: "o", repo: "r", number: 1)?.state == TriageState.pending.rawValue)
        #expect(store.record(owner: "o", repo: "r", number: 2)?.state == TriageState.preexisting.rawValue)
        #expect(store.record(owner: "o", repo: "r", number: 3)?.state == TriageState.preexisting.rawValue)
    }

    @Test func aiCreatedTaskNumbersCollectsCreatedTasks() throws {
        let store = try makeStore()
        store.upsert(owner: "o", repo: "r", number: 1) {
            $0.state = TriageState.autoApplied.rawValue
            $0.createdTaskNumber = 90
        }
        store.upsert(owner: "o", repo: "r", number: 2) { $0.state = TriageState.accepted.rawValue }
        #expect(store.aiCreatedTaskNumbers(owner: "o", repo: "r") == [90])
    }

    @Test func deleteAllRemovesEverything() throws {
        let store = try makeStore()
        store.upsert(owner: "o", repo: "r", number: 1) { $0.state = TriageState.pending.rawValue }
        store.upsert(owner: "o", repo: "other", number: 2) { $0.state = TriageState.autoApplied.rawValue }
        store.deleteAll()
        #expect(!store.hasRecord(owner: "o", repo: "r", number: 1))
        #expect(!store.hasRecord(owner: "o", repo: "other", number: 2))
    }

    @Test func deletePendingLeavesOtherStates() throws {
        let store = try makeStore()
        store.upsert(owner: "o", repo: "r", number: 1) { $0.state = TriageState.pending.rawValue }
        store.upsert(owner: "o", repo: "r", number: 2) { $0.state = TriageState.dismissed.rawValue }
        store.upsert(owner: "o", repo: "r", number: 3) { $0.state = TriageState.notActionable.rawValue }
        store.deletePending()
        #expect(!store.hasRecord(owner: "o", repo: "r", number: 1))
        #expect(store.record(owner: "o", repo: "r", number: 2)?.state == TriageState.dismissed.rawValue)
        #expect(store.record(owner: "o", repo: "r", number: 3)?.state == TriageState.notActionable.rawValue)
    }
}
