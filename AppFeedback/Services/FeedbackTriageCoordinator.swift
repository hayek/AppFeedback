import Foundation
import Observation

/// Seam over TaskService so triage tests run without GitHub or Keychain.
@MainActor
protocol TriageTaskApplying: AnyObject {
    func assign(feedbackNumber: Int, to task: TaskItem, in repo: ProductConfig) async throws
    /// Returns the created task's number.
    func createTask(in repo: ProductConfig, title: String, summary: String,
                    feedbackNumber: Int) async throws -> Int
}

@MainActor
final class TaskServiceTriageApplier: TriageTaskApplying {
    private let service: TaskService
    // Default-constructing `TaskService()` (a @MainActor type) as a parameter default
    // expression is evaluated in a nonisolated context by the compiler, so the fallback
    // is built inside the (already MainActor-isolated) initializer body instead.
    init(service: TaskService? = nil) { self.service = service ?? TaskService() }

    func assign(feedbackNumber: Int, to task: TaskItem, in repo: ProductConfig) async throws {
        var refs = Set(task.feedbackRefs)
        refs.insert(feedbackNumber)
        try await service.setFeedbackRefs(repo: repo, task: task, refs: refs.sorted())
    }

    func createTask(in repo: ProductConfig, title: String, summary: String,
                    feedbackNumber: Int) async throws -> Int {
        try await service.createTask(repo: repo, title: title, prose: summary,
                                     feedbackRefs: [feedbackNumber],
                                     status: .todo, priority: .med, milestoneNumber: nil)
    }
}

/// Orchestrates AI feedback triage: filters new feedback, runs the two-stage
/// pipeline, and routes outcomes by `TriageMode`. Serial by design — one on-device
/// inference at a time, and a batch's created tasks join the roster so five
/// duplicate crash reports become one create plus four assigns.
@Observable @MainActor
final class FeedbackTriageCoordinator {
    private let provider: IntelligenceProvider
    private let store: TriageVerdictStore
    private let settings: TriageSettings
    private let applier: TriageTaskApplying

    private(set) var isProcessing = false
    /// (processed, total) for the running pass — drives backfill progress UI.
    private(set) var progress: (done: Int, total: Int)?

    init(provider: IntelligenceProvider, store: TriageVerdictStore,
         settings: TriageSettings, applier: TriageTaskApplying) {
        self.provider = provider
        self.store = store
        self.settings = settings
        self.applier = applier
    }

    typealias RepoGroup = (repo: ProductConfig, issues: [FeedbackIssue])

    // MARK: Entry points

    /// Refresh hook: triages feedback with no verdict yet. First sighting of a repo
    /// snapshots the existing backlog as `.preexisting` instead (no AI calls).
    func processLoaded(_ groups: [RepoGroup]) async {
        guard begin() else { return }
        defer { end() }
        for group in groups {
            await processRepo(group, retriableStates: [])
        }
    }

    /// Manual backfill over one product: re-triages `.preexisting` and `.skipped`
    /// records (plus `.dismissed`/`.notActionable` when `rerunSettled`).
    func runBackfill(repo: ProductConfig, issues: [FeedbackIssue], rerunSettled: Bool = false) async {
        guard begin() else { return }
        defer { end() }
        settings.markSnapshotted(owner: repo.owner, repo: repo.repo)
        let retriable: Set<TriageState> = rerunSettled
            ? [.preexisting, .skipped, .dismissed, .notActionable]
            : [.preexisting, .skipped]
        await processRepo((repo, issues), retriableStates: retriable)
    }

    /// Applies a pending suggestion (chip Accept).
    func accept(record: TriageVerdictRecord, repo: ProductConfig, issues: [FeedbackIssue]) async throws {
        let tasks = issues.filter(TaskItem.isTask).map(TaskItem.init(issue:))
        if let n = record.suggestedTaskNumber, let task = tasks.first(where: { $0.number == n }) {
            try await applier.assign(feedbackNumber: record.feedbackNumber, to: task, in: repo)
        } else if let title = record.suggestedTitle {
            record.createdTaskNumber = try await applier.createTask(
                in: repo, title: title, summary: record.suggestedSummary ?? "",
                feedbackNumber: record.feedbackNumber)
        } else {
            throw IntelligenceError.empty   // malformed record: nothing to apply
        }
        store.setState(record, .accepted)
    }

    func dismiss(record: TriageVerdictRecord) {
        store.setState(record, .dismissed)
    }

    /// DEBUG: forget every triage verdict so unlinked feedback re-triages.
    func clearAllVerdicts() {
        store.deleteAll()
    }

    /// DEBUG: forget pending suggestions only.
    func clearPendingSuggestions() {
        store.deletePending()
    }

    // MARK: UI queries

    func pendingSuggestion(owner: String, repo: String, number: Int) -> TriageVerdictRecord? {
        guard let rec = store.record(owner: owner, repo: repo, number: number),
              rec.state == TriageState.pending.rawValue else { return nil }
        return rec
    }

    func aiCreatedTaskNumbers(owner: String, repo: String) -> Set<Int> {
        store.aiCreatedTaskNumbers(owner: owner, repo: repo)
    }

    // MARK: Pipeline

    private func begin() -> Bool {
        guard settings.mode != .off, provider.availability.isReady, !isProcessing else { return false }
        isProcessing = true
        return true
    }

    private func end() {
        isProcessing = false
        progress = nil
    }

    private func processRepo(_ group: RepoGroup, retriableStates: Set<TriageState>) async {
        let repo = group.repo
        let tasks = group.issues.filter(TaskItem.isTask).map(TaskItem.init(issue:))
        var linked = Set(tasks.flatMap(\.feedbackRefs))
        let feedback = group.issues.filter { !TaskItem.isTask($0) }

        if !settings.hasSnapshotted(owner: repo.owner, repo: repo.repo) {
            store.snapshotPreexisting(owner: repo.owner, repo: repo.repo,
                                      numbers: feedback.map(\.number).filter { !linked.contains($0) })
            settings.markSnapshotted(owner: repo.owner, repo: repo.repo)
            return
        }

        // A task's linked feedback conveys its real meaning — task titles are often too
        // terse for the pairwise verifier to judge alone. Resolve up to 3 from this pass.
        let feedbackTitleByNumber = Dictionary(
            feedback.map { ($0.number, $0.title) }, uniquingKeysWith: { first, _ in first })
        var roster = tasks.filter { !$0.isCompleted }
            .map { task in
                let covered = task.feedbackRefs.prefix(3).compactMap { feedbackTitleByNumber[$0] }
                return TriageTaskRosterEntry(number: task.number, title: task.title,
                                             coveredFeedbackTitles: Array(covered))
            }
        var taskByNumber = Dictionary(uniqueKeysWithValues: tasks.map { ($0.number, $0) })

        let candidates = feedback.filter { issue in
            guard !linked.contains(issue.number) else { return false }
            guard let rec = store.record(owner: repo.owner, repo: repo.repo, number: issue.number) else {
                return true
            }
            return TriageState(rawValue: rec.state).map(retriableStates.contains) ?? false
        }
        guard !candidates.isEmpty else { return }
        progress = (0, candidates.count)

        for (index, issue) in candidates.enumerated() {
            await triageOne(issue, repo: repo, roster: &roster,
                            taskByNumber: &taskByNumber, linked: &linked)
            progress = (index + 1, candidates.count)
        }
    }

    private func triageOne(_ issue: FeedbackIssue, repo: ProductConfig,
                           roster: inout [TriageTaskRosterEntry],
                           taskByNumber: inout [Int: TaskItem],
                           linked: inout Set<Int>) async {
        let classification: TriageClassificationDTO
        do {
            classification = try await provider.triageClassify(issue: issue)
        } catch {
            // Guardrail block, exhausted context ladder, or transient failure:
            // park as skipped so refreshes don't retry; backfill can.
            store.upsert(owner: repo.owner, repo: repo.repo, number: issue.number) {
                $0.state = TriageState.skipped.rawValue
            }
            return
        }

        guard classification.isActionable, let kind = classification.kind else {
            store.upsert(owner: repo.owner, repo: repo.repo, number: issue.number) {
                $0.state = TriageState.notActionable.rawValue
                $0.isActionable = false
                $0.signal = classification.signal
            }
            return
        }

        let decision: TriageDecisionDTO
        do {
            decision = try await provider.triageMatch(
                feedbackTitle: issue.title, signal: classification.signal, kind: kind, roster: roster)
        } catch {
            store.upsert(owner: repo.owner, repo: repo.repo, number: issue.number) {
                $0.state = TriageState.skipped.rawValue
            }
            return
        }

        await route(decision, for: issue, repo: repo, classification: classification,
                    kind: kind, roster: &roster, taskByNumber: &taskByNumber, linked: &linked)
    }

    private func route(_ decision: TriageDecisionDTO, for issue: FeedbackIssue,
                       repo: ProductConfig, classification: TriageClassificationDTO,
                       kind: TriageKind,
                       roster: inout [TriageTaskRosterEntry],
                       taskByNumber: inout [Int: TaskItem],
                       linked: inout Set<Int>) async {
        func recordSuggestion(_ state: TriageState) {
            store.upsert(owner: repo.owner, repo: repo.repo, number: issue.number) { rec in
                rec.state = state.rawValue
                rec.isActionable = true
                rec.kind = kind.rawValue
                rec.signal = classification.signal
                switch decision {
                case .assign(let n):
                    rec.suggestedTaskNumber = n
                case .createNew(let title, let summary):
                    rec.suggestedTitle = title
                    rec.suggestedSummary = summary
                }
            }
        }

        switch (decision, settings.mode) {
        case (.assign(let n), .hybrid), (.assign(let n), .fullAuto):
            // Race re-check: the freshly loaded pass may already link this feedback.
            guard let task = taskByNumber[n], !linked.contains(issue.number) else {
                recordSuggestion(.pending)
                return
            }
            do {
                try await applier.assign(feedbackNumber: issue.number, to: task, in: repo)
                linked.insert(issue.number)
                taskByNumber[n] = task.withFeedbackRefs(task.feedbackRefs + [issue.number])
                recordSuggestion(.autoApplied)
            } catch {
                recordSuggestion(.pending)   // demoted; chip offers retry via Accept
            }

        case (.createNew(let title, let summary), .fullAuto):
            do {
                let created = try await applier.createTask(
                    in: repo, title: title, summary: summary, feedbackNumber: issue.number)
                linked.insert(issue.number)
                roster.append(TriageTaskRosterEntry(number: created, title: title,
                                                    coveredFeedbackTitles: [issue.title]))
                taskByNumber[created] = TaskItem(
                    number: created, title: title,
                    body: TaskService.body(prose: summary, feedbackRefs: [issue.number]),
                    feedbackRefs: [issue.number], status: .todo, priority: .med,
                    milestoneTitle: nil, isClosed: false)
                store.upsert(owner: repo.owner, repo: repo.repo, number: issue.number) { rec in
                    rec.state = TriageState.autoApplied.rawValue
                    rec.isActionable = true
                    rec.kind = kind.rawValue
                    rec.signal = classification.signal
                    rec.suggestedTitle = title
                    rec.suggestedSummary = summary
                    rec.createdTaskNumber = created
                }
            } catch {
                recordSuggestion(.pending)
            }

        default:
            // Suggest mode entirely, and hybrid's createNew.
            recordSuggestion(.pending)
        }
    }
}
