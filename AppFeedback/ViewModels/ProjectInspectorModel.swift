import Foundation
import Observation

@Observable @MainActor
final class ProjectInspectorModel {
    private(set) var tasks: [TaskItem] = []
    var statusFilter: TaskStatus? = nil

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

    var filteredTasks: [TaskItem] {
        guard let statusFilter else { return tasks }
        return tasks.filter { ($0.status == statusFilter && !$0.isClosed) || (statusFilter == .done && $0.isCompleted) }
    }

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
