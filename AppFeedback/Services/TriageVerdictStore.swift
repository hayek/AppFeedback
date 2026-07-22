import Foundation
import SwiftData

/// Fetch/upsert layer over `TriageVerdictRecord`. @MainActor like the other
/// SwiftData-backed stores; the coordinator is the only writer.
@MainActor
final class TriageVerdictStore {
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    func record(owner: String, repo: String, number: Int) -> TriageVerdictRecord? {
        var descriptor = FetchDescriptor<TriageVerdictRecord>(predicate: #Predicate {
            $0.repoOwner == owner && $0.repoName == repo && $0.feedbackNumber == number
        })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    func hasRecord(owner: String, repo: String, number: Int) -> Bool {
        record(owner: owner, repo: repo, number: number) != nil
    }

    func pendingSuggestions(owner: String, repo: String) -> [TriageVerdictRecord] {
        let raw = TriageState.pending.rawValue
        let descriptor = FetchDescriptor<TriageVerdictRecord>(
            predicate: #Predicate { $0.repoOwner == owner && $0.repoName == repo && $0.state == raw },
            sortBy: [SortDescriptor(\.feedbackNumber)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Pending create-suggestions (no target task, has a proposed title), newest
    /// first — the dedup candidates for a newly proposed task.
    func pendingCreateSuggestions(owner: String, repo: String) -> [TriageVerdictRecord] {
        let raw = TriageState.pending.rawValue
        let descriptor = FetchDescriptor<TriageVerdictRecord>(
            predicate: #Predicate {
                $0.repoOwner == owner && $0.repoName == repo && $0.state == raw
                    && $0.suggestedTaskNumber == nil && $0.suggestedTitle != nil
            },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Numbers of tasks that were created by AI (accepted or auto-applied creates).
    func aiCreatedTaskNumbers(owner: String, repo: String) -> Set<Int> {
        let descriptor = FetchDescriptor<TriageVerdictRecord>(predicate: #Predicate {
            $0.repoOwner == owner && $0.repoName == repo && $0.createdTaskNumber != nil
        })
        return Set(((try? context.fetch(descriptor)) ?? []).compactMap(\.createdTaskNumber))
    }

    @discardableResult
    func upsert(owner: String, repo: String, number: Int,
                mutate: (TriageVerdictRecord) -> Void) -> TriageVerdictRecord {
        let rec = record(owner: owner, repo: repo, number: number)
            ?? {
                let fresh = TriageVerdictRecord(repoOwner: owner, repoName: repo,
                                                feedbackNumber: number,
                                                state: TriageState.pending.rawValue)
                context.insert(fresh)
                return fresh
            }()
        mutate(rec)
        rec.updatedAt = Date()
        try? context.save()
        return rec
    }

    /// Marks feedback that predates triage as `.preexisting` — insert-if-missing only,
    /// so real verdicts are never downgraded (mirrors NotificationService.snapshotExistingIssues).
    func snapshotPreexisting(owner: String, repo: String, numbers: [Int]) {
        for number in numbers where !hasRecord(owner: owner, repo: repo, number: number) {
            context.insert(TriageVerdictRecord(repoOwner: owner, repoName: repo,
                                               feedbackNumber: number,
                                               state: TriageState.preexisting.rawValue))
        }
        try? context.save()
    }

    func setState(_ record: TriageVerdictRecord, _ state: TriageState) {
        record.state = state.rawValue
        record.updatedAt = Date()
        try? context.save()
    }

    /// DEBUG re-test aid: forgets every verdict across all repos. Snapshot markers
    /// are untouched, so the next pass re-triages instead of re-snapshotting.
    func deleteAll() {
        let all = (try? context.fetch(FetchDescriptor<TriageVerdictRecord>())) ?? []
        for record in all { context.delete(record) }
        try? context.save()
    }

    /// DEBUG re-test aid: forgets only pending suggestions (the visible chips).
    func deletePending() {
        let raw = TriageState.pending.rawValue
        let descriptor = FetchDescriptor<TriageVerdictRecord>(predicate: #Predicate { $0.state == raw })
        for record in (try? context.fetch(descriptor)) ?? [] { context.delete(record) }
        try? context.save()
    }
}
