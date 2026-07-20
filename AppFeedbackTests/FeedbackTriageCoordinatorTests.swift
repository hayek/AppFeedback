import Testing
import Foundation
import SwiftData
@testable import AppFeedback

private struct TriageTestError: Error, Equatable {}

@MainActor
struct FeedbackTriageCoordinatorTests {
    @MainActor
    struct Harness {
        let provider = MockIntelligenceProvider()
        let applier = MockTriageApplier()
        let store: TriageVerdictStore
        let settings: TriageSettings
        let coordinator: FeedbackTriageCoordinator
        let repo = ProductConfig(displayName: "P", owner: "o", repo: "r")

        init(mode: TriageMode) throws {
            let config = ModelConfiguration(isStoredInMemoryOnly: true)
            let container = try ModelContainer(for: TriageVerdictRecord.self, configurations: config)
            store = TriageVerdictStore(context: ModelContext(container))
            settings = TriageSettings(defaults: UserDefaults(suiteName: "triage-co-\(UUID())")!)
            settings.mode = mode
            coordinator = FeedbackTriageCoordinator(
                provider: provider, store: store, settings: settings, applier: applier)
        }

        /// Skips the first-sighting snapshot so tests exercise triage directly.
        func markSnapshotted() { settings.markSnapshotted(owner: "o", repo: "r") }
    }

    // MARK: 1. offModeDoesNothing

    @Test func offModeDoesNothing() async throws {
        let h = try Harness(mode: .off)
        let feedback = FeedbackIssue.triageTestFixture(number: 1)
        await h.coordinator.processLoaded([(repo: h.repo, issues: [feedback])])

        #expect(h.provider.triageClassifyCalls.isEmpty)
        #expect(h.store.record(owner: "o", repo: "r", number: 1) == nil)
        #expect(h.settings.hasSnapshotted(owner: "o", repo: "r") == false)
        #expect(h.coordinator.isProcessing == false)
    }

    // MARK: 2. firstSightingSnapshotsBacklogWithoutAI

    @Test func firstSightingSnapshotsBacklogWithoutAI() async throws {
        let h = try Harness(mode: .suggest)
        // Deliberately not calling markSnapshotted(): this is the repo's first sighting.
        let feedback = [
            FeedbackIssue.triageTestFixture(number: 1),
            FeedbackIssue.triageTestFixture(number: 2),
            FeedbackIssue.triageTestFixture(number: 3),
        ]
        await h.coordinator.processLoaded([(repo: h.repo, issues: feedback)])

        #expect(h.provider.triageClassifyCalls.isEmpty)
        #expect(h.settings.hasSnapshotted(owner: "o", repo: "r") == true)
        for number in [1, 2, 3] {
            let record = try #require(h.store.record(owner: "o", repo: "r", number: number))
            #expect(record.state == TriageState.preexisting.rawValue)
        }
    }

    // MARK: 3. notActionableStoresVerdict

    @Test func notActionableStoresVerdict() async throws {
        let h = try Harness(mode: .suggest)
        h.markSnapshotted()
        h.provider.triageClassifyHandler = { _ in
            TriageClassificationDTO(isActionable: false, kind: nil, signal: "vague negativity")
        }
        let feedback = FeedbackIssue.triageTestFixture(number: 5)
        await h.coordinator.processLoaded([(repo: h.repo, issues: [feedback])])

        let record = try #require(h.store.record(owner: "o", repo: "r", number: 5))
        #expect(record.state == TriageState.notActionable.rawValue)
        #expect(record.isActionable == false)
        #expect(h.provider.triageMatchCalls.isEmpty)
        #expect(h.applier.assigns.isEmpty)
        #expect(h.applier.creates.isEmpty)
    }

    // MARK: 4. suggestModeStoresPendingForAssignAndCreate

    @Test func suggestModeStoresPendingForAssignAndCreate() async throws {
        let h = try Harness(mode: .suggest)
        h.markSnapshotted()
        h.provider.triageClassifyHandler = { issue in
            TriageClassificationDTO(isActionable: true, kind: .bug, signal: "signal \(issue.number)")
        }

        // Assign case: roster contains open task 42.
        let task42 = FeedbackIssue.triageTaskFixture(number: 42, title: "Existing task")
        h.provider.triageMatchHandler = { _, _, _ in .assign(taskNumber: 42) }
        let assignFeedback = FeedbackIssue.triageTestFixture(number: 10)
        await h.coordinator.processLoaded([(repo: h.repo, issues: [task42, assignFeedback])])

        let assignRecord = try #require(h.store.record(owner: "o", repo: "r", number: 10))
        #expect(assignRecord.state == TriageState.pending.rawValue)
        #expect(assignRecord.suggestedTaskNumber == 42)
        #expect(h.applier.assigns.isEmpty)
        #expect(h.applier.creates.isEmpty)

        // Create case.
        h.provider.triageMatchHandler = { _, _, _ in .createNew(title: "New task", summary: "Summary") }
        let createFeedback = FeedbackIssue.triageTestFixture(number: 11)
        await h.coordinator.processLoaded([(repo: h.repo, issues: [task42, createFeedback])])

        let createRecord = try #require(h.store.record(owner: "o", repo: "r", number: 11))
        #expect(createRecord.state == TriageState.pending.rawValue)
        #expect(createRecord.suggestedTitle == "New task")
        #expect(createRecord.suggestedSummary == "Summary")
        #expect(h.applier.assigns.isEmpty)
        #expect(h.applier.creates.isEmpty)
    }

    // MARK: 5. hybridAppliesAssignImmediately

    @Test func hybridAppliesAssignImmediately() async throws {
        let h = try Harness(mode: .hybrid)
        h.markSnapshotted()
        h.provider.triageClassifyHandler = { _ in
            TriageClassificationDTO(isActionable: true, kind: .bug, signal: "crash signal")
        }
        h.provider.triageMatchHandler = { _, _, _ in .assign(taskNumber: 42) }

        let task42 = FeedbackIssue.triageTaskFixture(number: 42, title: "Existing task")
        let feedback = FeedbackIssue.triageTestFixture(number: 7)
        await h.coordinator.processLoaded([(repo: h.repo, issues: [task42, feedback])])

        #expect(h.applier.assigns.count == 1)
        #expect(h.applier.assigns.first.map { $0 == (7, 42) } == true)
        let record = try #require(h.store.record(owner: "o", repo: "r", number: 7))
        #expect(record.state == TriageState.autoApplied.rawValue)
    }

    // MARK: 6. hybridLeavesCreateAsPending

    @Test func hybridLeavesCreateAsPending() async throws {
        let h = try Harness(mode: .hybrid)
        h.markSnapshotted()
        h.provider.triageClassifyHandler = { _ in
            TriageClassificationDTO(isActionable: true, kind: .featureRequest, signal: "feature signal")
        }
        h.provider.triageMatchHandler = { _, _, _ in .createNew(title: "New feature", summary: "Detail") }

        let feedback = FeedbackIssue.triageTestFixture(number: 8)
        await h.coordinator.processLoaded([(repo: h.repo, issues: [feedback])])

        #expect(h.applier.creates.isEmpty)
        let record = try #require(h.store.record(owner: "o", repo: "r", number: 8))
        #expect(record.state == TriageState.pending.rawValue)
        #expect(record.suggestedTitle == "New feature")
        #expect(record.suggestedSummary == "Detail")
    }

    // MARK: 7. fullAutoCreatesAndGrowsRoster

    @Test func fullAutoCreatesAndGrowsRoster() async throws {
        let h = try Harness(mode: .fullAuto)
        h.markSnapshotted()
        h.provider.triageClassifyHandler = { issue in
            TriageClassificationDTO(isActionable: true, kind: .bug, signal: "signal \(issue.number)")
        }

        var matchCallCount = 0
        h.provider.triageMatchHandler = { _, _, roster in
            matchCallCount += 1
            if matchCallCount == 1 {
                return .createNew(title: "Crash on export", summary: "Details")
            } else {
                #expect(roster.contains { $0.number == 901 })
                return .assign(taskNumber: 901)
            }
        }

        let f1 = FeedbackIssue.triageTestFixture(number: 20)
        let f2 = FeedbackIssue.triageTestFixture(number: 21)
        await h.coordinator.processLoaded([(repo: h.repo, issues: [f1, f2])])

        #expect(matchCallCount == 2)
        #expect(h.applier.creates.count == 1)
        #expect(h.applier.creates.first.map { $0.feedback == 20 } == true)
        #expect(h.applier.assigns.count == 1)
        #expect(h.applier.assigns.first.map { $0 == (21, 901) } == true)

        let record1 = try #require(h.store.record(owner: "o", repo: "r", number: 20))
        #expect(record1.state == TriageState.autoApplied.rawValue)
        #expect(record1.createdTaskNumber == 901)
        let record2 = try #require(h.store.record(owner: "o", repo: "r", number: 21))
        #expect(record2.state == TriageState.autoApplied.rawValue)
    }

    // MARK: 8. guardrailMarksSkipped

    @Test func guardrailMarksSkipped() async throws {
        let h = try Harness(mode: .suggest)
        h.markSnapshotted()
        h.provider.triageClassifyHandler = { issue in
            if issue.number == 30 { throw IntelligenceError.guardrailBlocked }
            return TriageClassificationDTO(isActionable: false, kind: nil, signal: "")
        }

        let f1 = FeedbackIssue.triageTestFixture(number: 30)
        let f2 = FeedbackIssue.triageTestFixture(number: 31)
        await h.coordinator.processLoaded([(repo: h.repo, issues: [f1, f2])])

        let record1 = try #require(h.store.record(owner: "o", repo: "r", number: 30))
        #expect(record1.state == TriageState.skipped.rawValue)
        // Processing continued to the next item.
        let record2 = try #require(h.store.record(owner: "o", repo: "r", number: 31))
        #expect(record2.state == TriageState.notActionable.rawValue)
        #expect(h.provider.triageMatchCalls.isEmpty)
    }

    // MARK: 9. applyFailureDemotesToPending

    @Test func applyFailureDemotesToPending() async throws {
        let h = try Harness(mode: .fullAuto)
        h.markSnapshotted()
        h.provider.triageClassifyHandler = { _ in
            TriageClassificationDTO(isActionable: true, kind: .bug, signal: "crash sig")
        }
        h.provider.triageMatchHandler = { _, _, _ in .assign(taskNumber: 42) }
        h.applier.errorToThrow = TriageTestError()

        let task42 = FeedbackIssue.triageTaskFixture(number: 42, title: "Existing task")
        let feedback = FeedbackIssue.triageTestFixture(number: 9)
        await h.coordinator.processLoaded([(repo: h.repo, issues: [task42, feedback])])

        #expect(h.applier.assigns.isEmpty)
        let record = try #require(h.store.record(owner: "o", repo: "r", number: 9))
        #expect(record.state == TriageState.pending.rawValue)
        #expect(record.suggestedTaskNumber == 42)
        #expect(record.isActionable == true)
        #expect(record.kind == TriageKind.bug.rawValue)
        #expect(record.signal == "crash sig")
    }

    // MARK: 10. alreadyLinkedAndAlreadyRecordedAreSkipped

    @Test func alreadyLinkedAndAlreadyRecordedAreSkipped() async throws {
        let h = try Harness(mode: .suggest)
        h.markSnapshotted()

        // Already linked: feedback #7 is referenced by task #100's feedbackRefs.
        let task100 = FeedbackIssue.triageTaskFixture(number: 100, title: "Linked task", refs: [7])
        let linkedFeedback = FeedbackIssue.triageTestFixture(number: 7)

        // Already recorded: feedback #8 already has a verdict.
        h.store.upsert(owner: "o", repo: "r", number: 8) { $0.state = TriageState.pending.rawValue }
        let recordedFeedback = FeedbackIssue.triageTestFixture(number: 8)

        await h.coordinator.processLoaded([(repo: h.repo, issues: [task100, linkedFeedback, recordedFeedback])])

        #expect(h.provider.triageClassifyCalls.isEmpty)
    }

    // MARK: 11. backfillProcessesPreexistingAndSkipped

    @Test func backfillProcessesPreexistingAndSkipped() async throws {
        let h = try Harness(mode: .suggest)
        h.provider.triageClassifyHandler = { _ in
            TriageClassificationDTO(isActionable: false, kind: nil, signal: "")
        }

        h.store.upsert(owner: "o", repo: "r", number: 1) { $0.state = TriageState.preexisting.rawValue }
        h.store.upsert(owner: "o", repo: "r", number: 2) { $0.state = TriageState.skipped.rawValue }
        h.store.upsert(owner: "o", repo: "r", number: 3) { $0.state = TriageState.dismissed.rawValue }
        h.store.upsert(owner: "o", repo: "r", number: 4) { $0.state = TriageState.notActionable.rawValue }

        let issues = [1, 2, 3, 4].map { FeedbackIssue.triageTestFixture(number: $0) }

        await h.coordinator.runBackfill(repo: h.repo, issues: issues, rerunSettled: false)
        let callsAfterFirst = Set(h.provider.triageClassifyCalls.map(\.number))
        #expect(callsAfterFirst.contains(1))
        #expect(callsAfterFirst.contains(2))
        #expect(!callsAfterFirst.contains(3))
        #expect(!callsAfterFirst.contains(4))

        await h.coordinator.runBackfill(repo: h.repo, issues: issues, rerunSettled: true)
        let callsAfterSecond = Set(h.provider.triageClassifyCalls.map(\.number))
        #expect(callsAfterSecond.contains(3))
        #expect(callsAfterSecond.contains(4))
    }

    // MARK: 12. acceptAppliesPendingSuggestion

    @Test func acceptAppliesPendingSuggestion() async throws {
        let h = try Harness(mode: .suggest)

        // Pending create.
        let createRecord = h.store.upsert(owner: "o", repo: "r", number: 50) {
            $0.state = TriageState.pending.rawValue
            $0.suggestedTitle = "New task title"
            $0.suggestedSummary = "New task summary"
        }
        try await h.coordinator.accept(record: createRecord, repo: h.repo, issues: [])
        #expect(h.applier.creates.count == 1)
        #expect(h.applier.creates.first.map { $0.title == "New task title" && $0.summary == "New task summary" && $0.feedback == 50 } == true)
        #expect(createRecord.state == TriageState.accepted.rawValue)
        #expect(createRecord.createdTaskNumber == 901)

        // Pending assign.
        let task42 = FeedbackIssue.triageTaskFixture(number: 42, title: "Existing task")
        let assignRecord = h.store.upsert(owner: "o", repo: "r", number: 51) {
            $0.state = TriageState.pending.rawValue
            $0.suggestedTaskNumber = 42
        }
        try await h.coordinator.accept(record: assignRecord, repo: h.repo, issues: [task42])
        #expect(h.applier.assigns.count == 1)
        #expect(h.applier.assigns.first.map { $0 == (51, 42) } == true)
        #expect(assignRecord.state == TriageState.accepted.rawValue)
    }

    // MARK: 13. dismissMarksDismissed

    @Test func dismissMarksDismissed() throws {
        let h = try Harness(mode: .suggest)
        let record = h.store.upsert(owner: "o", repo: "r", number: 60) {
            $0.state = TriageState.pending.rawValue
        }
        h.coordinator.dismiss(record: record)
        #expect(record.state == TriageState.dismissed.rawValue)
    }

    // MARK: 14. unavailableProviderIsNoOp

    @Test func unavailableProviderIsNoOp() async throws {
        let h = try Harness(mode: .suggest)
        h.provider.availability = .osTooOld

        let feedback = FeedbackIssue.triageTestFixture(number: 70)
        await h.coordinator.processLoaded([(repo: h.repo, issues: [feedback])])

        #expect(h.provider.triageClassifyCalls.isEmpty)
        #expect(h.store.record(owner: "o", repo: "r", number: 70) == nil)
        #expect(h.settings.hasSnapshotted(owner: "o", repo: "r") == false)
        #expect(h.coordinator.isProcessing == false)
    }
}
