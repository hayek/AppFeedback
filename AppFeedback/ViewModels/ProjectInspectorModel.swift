import Foundation
import Observation
import SwiftUI   // for `withAnimation` around the badge-clear timers

/// The values entered in `CreateTaskSheet`, captured so the task can be shown optimistically
/// and the GitHub write driven from `RootView` after the sheet dismisses. `milestoneTitle` is
/// carried (alongside `milestoneNumber`) purely so the optimistic card can show the version name.
struct TaskDraft: Equatable {
    var title: String
    var prose: String
    var status: TaskStatus
    var priority: TaskPriority
    var milestoneNumber: Int?
    var milestoneTitle: String?
}

/// The values entered in `NewVersionSheet`, captured so the version can be created locally at
/// once and the GitHub milestone provisioned in the background (mirrors `TaskDraft`).
struct VersionDraft: Equatable {
    var name: String
    var releaseTitle: String
    var changelog: String
}

/// The lifecycle of an optimistic create (a task or a version), shown as a status badge:
/// a "Creating…" shimmer, a green animated "Created ✓" that fades out, or a "Failed" with
/// Retry/Dismiss. Shared by `TaskCreation` and `CreationStatusTracker`.
enum CreationPhase: Equatable {
    case creating
    case created           // green checkmark; auto-cleared after `creationBadgeLinger`
    case failed(String)    // persists with Retry/Dismiss until the user acts
}

/// An in-flight (or just-finished) task creation, shown as an optimistic card with a status
/// badge before/while GitHub confirms it. Mirrors the mail "Sending…" badge: the card appears
/// the instant the user taps Create, then resolves to a checkmark or a failure.
struct TaskCreation: Identifiable, Equatable {
    let id: UUID
    /// Monotonic creation order. Used to sort placeholder cards among themselves so they keep a
    /// stable, oldest-first order — matching the ascending issue-number order they'll take once
    /// they reload, so no card reorders when one's real issue arrives.
    let sequence: Int
    var draft: TaskDraft
    var phase: CreationPhase
    /// The GitHub issue number, known once `.created`. Once its real (reloaded) task appears in
    /// `tasks`, this lets the badge ride on that real card instead of a duplicate placeholder.
    var number: Int?
}

/// The task Version filter's value: no constraint, a single derived state (resolved live so
/// versions added later are covered), or an explicit set of milestone names. State and a fresh
/// specific-version pick replace the whole value; a second specific-version pick is additive.
enum VersionScope: Equatable, Codable {
    case any
    case state(VersionState)
    case versions(Set<String>)
}

/// Active filters for the inspector's Tasks section. An empty set on a dimension means "no
/// constraint"; dimensions combine with AND. `search` is matched by `TaskItem.matchesSearch`.
struct TaskFilters: Equatable {
    var statuses:   Set<TaskStatus>   = []
    var priorities: Set<TaskPriority> = []
    var versionScope: VersionScope    = .any
    var search:     String            = ""

    var isActive: Bool {
        !statuses.isEmpty || !priorities.isEmpty || versionScope != .any
            || !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func isStateSelected(_ s: VersionState) -> Bool { versionScope == .state(s) }

    func isVersionSelected(_ name: String) -> Bool {
        if case .versions(let names) = versionScope { return names.contains(name) }
        return false
    }

    /// Selecting a state replaces the whole scope; re-selecting the active state clears to `.any`.
    mutating func toggleState(_ s: VersionState) {
        versionScope = (versionScope == .state(s)) ? .any : .state(s)
    }

    /// A specific-version pick overrides a state/`.any`; a second pick is additive. Emptying → `.any`.
    mutating func toggleVersion(_ name: String) {
        if case .versions(var names) = versionScope {
            if names.contains(name) { names.remove(name) } else { names.insert(name) }
            versionScope = names.isEmpty ? .any : .versions(names)
        } else {
            versionScope = .versions([name])
        }
    }

    /// Clears any version constraint (state or specific names) back to `.any`.
    mutating func clearVersionScope() { versionScope = .any }
}

/// Active filters for the inspector's Versions section: by derived `VersionState` and a name/
/// title search. Empty `states` means "no constraint".
struct VersionFilters: Equatable {
    var states: Set<VersionState> = []
    var search: String            = ""

    var isActive: Bool {
        !states.isEmpty || !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

@Observable @MainActor
final class ProjectInspectorModel {
    private(set) var tasks: [TaskItem] = []
    var taskFilters    = TaskFilters()
    var versionFilters = VersionFilters()
    /// Derived state per version name, pushed from `RootView`. Drives `.state` version filtering.
    var versionStates: [String: VersionState] = [:]

    // MARK: - Optimistic task creation

    /// How long the green "Created ✓" badge lingers before it's cleared from the (by then real)
    /// task card.
    static let creationBadgeLinger: Duration = .seconds(5)
    /// Max extra wait, after the linger, for the reloaded issue to appear before clearing the
    /// card anyway — so a creation whose refresh never lands doesn't show "Created" forever.
    private static let creationRealTaskWaitTicks = 12   // × 500ms ≈ 6s

    /// Optimistic creations: in-flight or just-finished task writes. A `.created` one whose issue
    /// has reloaded into `tasks` is shown as a badge on the real card (see `creationBadge`);
    /// the rest render as their own placeholder cards (see `pendingCreations`). Survives the
    /// `setTasks` reloads that rebuild `tasks` from GitHub read state.
    private(set) var creations: [TaskCreation] = []
    private var creationTimers: [UUID: Task<Void, Never>] = [:]
    private var creationSequence = 0

    /// Inserts an optimistic "Creating…" card and returns its id for the caller to drive.
    @discardableResult
    func beginCreation(_ draft: TaskDraft) -> UUID {
        let id = UUID()
        creationSequence += 1
        creations.insert(TaskCreation(id: id, sequence: creationSequence, draft: draft, phase: .creating, number: nil), at: 0)
        return id
    }

    /// Marks a creation succeeded: shows the checkmark and schedules the badge's removal.
    func markCreated(id: UUID, number: Int) {
        guard let i = creations.firstIndex(where: { $0.id == id }) else { return }
        creations[i].number = number
        creations[i].phase = .created
        scheduleRemoval(id: id)
    }

    /// Marks a creation failed: the card persists (with its reason) for Retry/Dismiss.
    func markFailed(id: UUID, reason: String) {
        cancelTimer(id)
        guard let i = creations.firstIndex(where: { $0.id == id }) else { return }
        creations[i].number = nil
        creations[i].phase = .failed(reason)
    }

    /// Returns a failed creation to "Creating…" so the caller can re-attempt the write. Returns
    /// `false` (and does nothing) if it isn't currently failed — guarding against a double-tap of
    /// Retry firing two concurrent GitHub writes.
    @discardableResult
    func retryCreation(id: UUID) -> Bool {
        guard let i = creations.firstIndex(where: { $0.id == id }),
              case .failed = creations[i].phase else { return false }
        cancelTimer(id)
        creations[i].number = nil
        creations[i].phase = .creating
        return true
    }

    func draft(forCreation id: UUID) -> TaskDraft? {
        creations.first { $0.id == id }?.draft
    }

    func removeCreation(id: UUID) {
        cancelTimer(id)
        creations.removeAll { $0.id == id }
    }

    /// Drops any creation card tracking the given issue number (e.g. when that task is deleted
    /// mid-badge, so a "Created ✓" card for a now-gone issue doesn't linger).
    func removeCreation(forTaskNumber number: Int) {
        for creation in creations where creation.number == number {
            removeCreation(id: creation.id)
        }
    }

    /// Drops all optimistic creations (e.g. when switching repos so a pending card from one
    /// project can't bleed into another).
    func clearCreations() {
        for (_, timer) in creationTimers { timer.cancel() }
        creationTimers.removeAll()
        creations.removeAll()
    }

    /// The badge to overlay on the real task card for `number`, if a just-created creation is
    /// still tracking it. Only `.created` creations carry a number, so this returns their phase.
    func creationBadge(forTaskNumber number: Int) -> CreationPhase? {
        creations.first { $0.number == number }?.phase
    }

    /// Creations that have no matching real task yet (still creating, failed, or created-but-not-
    /// reloaded) — rendered as their own placeholder cards rather than as a badge on a real card.
    func pendingCreations(loadedTaskNumbers present: Set<Int>) -> [TaskCreation] {
        creations.filter { creation in
            guard let number = creation.number else { return true }
            return !present.contains(number)
        }
    }

    /// Clears the badge a short linger after the green checkmark is actually showing. First waits
    /// (capped) for the reloaded issue so the *real* card is the one wearing "Created ✓", then
    /// lets it linger `creationBadgeLinger` before clearing — so the checkmark dwells the full
    /// time no matter how slow the refresh was. The cap means a creation whose refresh never
    /// lands still clears.
    private func scheduleRemoval(id: UUID) {
        cancelTimer(id)
        creationTimers[id] = Task { [weak self] in
            for _ in 0..<Self.creationRealTaskWaitTicks {
                if Task.isCancelled { return }
                guard let self, self.creations.contains(where: { $0.id == id }) else { return }
                if !self.awaitingReloadedTask(forCreation: id) { break }
                try? await Task.sleep(for: .milliseconds(500))
            }
            try? await Task.sleep(for: Self.creationBadgeLinger)
            if Task.isCancelled { return }
            withAnimation(.easeInOut(duration: 0.4)) { self?.removeCreation(id: id) }
        }
    }

    /// True while a `.created` creation's reloaded issue hasn't shown up in `tasks` yet.
    private func awaitingReloadedTask(forCreation id: UUID) -> Bool {
        guard let creation = creations.first(where: { $0.id == id }),
              let number = creation.number else { return false }
        return !tasks.contains { $0.number == number }
    }

    private func cancelTimer(_ id: UUID) {
        creationTimers[id]?.cancel()
        creationTimers[id] = nil
    }

    /// Optimistic feedback-ref edits awaiting GitHub confirmation, keyed by task number.
    /// A reload (`setTasks`) rebuilds `tasks` from GitHub read state, which lags a just-written
    /// ref change (read-replica / incremental-cache lag). Without this, a reload landing before
    /// the write propagates would clobber the optimistic attach/detach — so we re-apply pending
    /// overrides on every reload and self-clear each one only once the reload's refs match.
    private var pendingRefs: [Int: [Int]] = [:]

    /// Replaces the task list from a reload, re-applying any still-unconfirmed ref overrides on top.
    func setTasks(_ incoming: [TaskItem]) {
        guard !pendingRefs.isEmpty else { self.tasks = incoming; return }
        var result = incoming
        for (number, refs) in pendingRefs {
            guard let index = result.firstIndex(where: { $0.number == number }) else {
                pendingRefs[number] = nil        // task gone upstream (closed/deleted) — drop it
                continue
            }
            if Set(result[index].feedbackRefs) == Set(refs) {
                pendingRefs[number] = nil         // GitHub caught up — stop overriding
            } else {
                result[index] = result[index].withFeedbackRefs(refs)   // keep the optimistic edit visible
            }
        }
        self.tasks = result
    }

    /// Optimistically set a task's feedback refs and record the override so a stale reload can't
    /// clobber it. Returns the previous `TaskItem` (for `revertPending` on write failure).
    @discardableResult
    func setPendingRefs(number: Int, refs: [Int]) -> TaskItem? {
        let sorted = refs.sorted()
        pendingRefs[number] = sorted
        guard let index = tasks.firstIndex(where: { $0.number == number }) else { return nil }
        let previous = tasks[index]
        tasks[index] = previous.withFeedbackRefs(sorted)
        return previous
    }

    /// Roll a pending ref override back (used when the GitHub write fails). No-op if a fresh
    /// reload already resolved the override, so we never clobber newer data.
    func revertPending(number: Int, to previous: TaskItem) {
        guard pendingRefs[number] != nil else { return }
        pendingRefs[number] = nil
        guard let index = tasks.firstIndex(where: { $0.number == number }) else { return }
        tasks[index] = previous
    }

    /// Optimistically reflect a status/priority change in the UI before the GitHub write returns.
    /// Returns the previous `TaskItem` (for `restore` on failure), or nil if the task isn't loaded.
    @discardableResult
    func applyOptimistic(number: Int, status: TaskStatus? = nil, priority: TaskPriority? = nil,
                         title: String? = nil, body: String? = nil, milestone: String?? = nil) -> TaskItem? {
        guard let index = tasks.firstIndex(where: { $0.number == number }) else { return nil }
        let previous = tasks[index]
        tasks[index] = previous.with(status: status, priority: priority, title: title, body: body, milestone: milestone)
        return previous
    }

    /// Roll an optimistic change back to a previously-captured value (used when the write fails).
    func restore(_ task: TaskItem) {
        guard let index = tasks.firstIndex(where: { $0.number == task.number }) else { return }
        tasks[index] = task
    }

    /// Optimistically remove a task (used when deleting). A later refresh restores it if the
    /// GitHub delete failed.
    func removeTask(number: Int) {
        tasks.removeAll { $0.number == number }
    }

    /// Tasks passing all active filters (status, priority, version scope, search) — empty
    /// dimensions impose no constraint, and the dimensions combine with AND.
    var filteredTasks: [TaskItem] {
        tasks.filter { t in
            (taskFilters.statuses.isEmpty   || taskFilters.statuses.contains(t.displayStatus)) &&
            (taskFilters.priorities.isEmpty || taskFilters.priorities.contains(t.priority)) &&
            versionScopeMatches(t) &&
            t.matchesSearch(taskFilters.search)
        }
    }

    /// Resolves the task against the active `VersionScope`. `.state` looks the task's milestone up
    /// in `versionStates`; version-less tasks match neither `.state` nor `.versions`.
    private func versionScopeMatches(_ t: TaskItem) -> Bool {
        switch taskFilters.versionScope {
        case .any:                 return true
        case .state(let s):        return (t.milestoneTitle.flatMap { versionStates[$0] }) == s
        case .versions(let names): return names.contains(t.milestoneTitle ?? "")
        }
    }

    /// Distinct, sorted version names present among the loaded tasks (drives the Version filter
    /// menu). Excludes tasks with no version.
    var uniqueTaskVersions: [String] {
        Array(Set(tasks.compactMap(\.milestoneTitle)))
            .sorted { $0.compare($1, options: .numeric) == .orderedAscending }
    }

    /// Pure predicate for the Versions section filter; the panel supplies each version's derived
    /// `state`. No filters → matches everything.
    func versionMatches(name: String, releaseTitle: String, state: VersionState) -> Bool {
        let stateOK = versionFilters.states.isEmpty || versionFilters.states.contains(state)
        let q = versionFilters.search.trimmingCharacters(in: .whitespacesAndNewlines)
        let searchOK = q.isEmpty
            || name.localizedCaseInsensitiveContains(q)
            || releaseTitle.localizedCaseInsensitiveContains(q)
        return stateOK && searchOK
    }

    func clearTaskFilters()    { taskFilters = TaskFilters() }
    func clearVersionFilters() { versionFilters = VersionFilters() }
    func clearFilters()        { clearTaskFilters(); clearVersionFilters() }

    func task(number: Int) -> TaskItem? {
        tasks.first { $0.number == number }
    }

    func tasks(forVersionNamed name: String) -> [TaskItem] {
        tasks.filter { $0.milestoneTitle == name }
    }

    /// A version is "started" (→ wip) when any of its tasks is in progress or completed.
    func anyTaskStarted(versionNamed name: String) -> Bool {
        tasks(forVersionNamed: name).contains { $0.status == .inProgress || $0.isCompleted }
    }

    /// Completed feedback numbers for a version (drives recipient computation).
    func completedFeedbackNumbers(versionNamed name: String) -> [Int] {
        let refs = tasks(forVersionNamed: name).filter(\.isCompleted).flatMap(\.feedbackRefs)
        return Array(Set(refs)).sorted()
    }
}

/// Tracks the creation-status badge for entities whose real card already exists the instant
/// they're created (e.g. a version, created locally before its GitHub milestone is provisioned).
/// Keyed by the entity's stable id. Simpler than `ProjectInspectorModel`'s task creations — no
/// placeholder/hand-off, since the card is there from the start; the badge just rides on it.
@Observable @MainActor
final class CreationStatusTracker {
    private(set) var statuses: [UUID: CreationPhase] = [:]
    private var timers: [UUID: Task<Void, Never>] = [:]

    func status(_ id: UUID) -> CreationPhase? { statuses[id] }

    func begin(_ id: UUID) { cancel(id); statuses[id] = .creating }

    /// Shows the checkmark, then clears the badge after the linger.
    func succeed(_ id: UUID) {
        statuses[id] = .created
        cancel(id)
        timers[id] = Task { [weak self] in
            try? await Task.sleep(for: ProjectInspectorModel.creationBadgeLinger)
            if Task.isCancelled { return }
            withAnimation(.easeInOut(duration: 0.4)) { self?.clear(id) }
        }
    }

    func fail(_ id: UUID, reason: String) { cancel(id); statuses[id] = .failed(reason) }

    /// Returns the badge to "Creating…" so the caller can re-attempt — but only from `.failed`,
    /// so a double-tap of Retry can't fire two concurrent writes.
    @discardableResult
    func retry(_ id: UUID) -> Bool {
        guard case .failed = statuses[id] else { return false }
        cancel(id); statuses[id] = .creating; return true
    }

    func clear(_ id: UUID) { cancel(id); statuses[id] = nil }

    func clearAll() {
        for (_, timer) in timers { timer.cancel() }
        timers.removeAll()
        statuses.removeAll()
    }

    private func cancel(_ id: UUID) { timers[id]?.cancel(); timers[id] = nil }
}
