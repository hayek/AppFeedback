import Foundation
import Observation

@Observable @MainActor
final class ProjectInspectorModel {
    private(set) var tasks: [TaskItem] = []
    var statusFilter: TaskStatus? = nil

    func setTasks(_ tasks: [TaskItem]) { self.tasks = tasks }

    /// Optimistically reflect a status/priority change in the UI before the GitHub write returns.
    /// Returns the previous `TaskItem` (for `restore` on failure), or nil if the task isn't loaded.
    @discardableResult
    func applyOptimistic(number: Int, status: TaskStatus? = nil, priority: TaskPriority? = nil,
                         title: String? = nil, body: String? = nil) -> TaskItem? {
        guard let index = tasks.firstIndex(where: { $0.number == number }) else { return nil }
        let previous = tasks[index]
        tasks[index] = previous.with(status: status, priority: priority, title: title, body: body)
        return previous
    }

    /// Roll an optimistic change back to a previously-captured value (used when the write fails).
    func restore(_ task: TaskItem) {
        guard let index = tasks.firstIndex(where: { $0.number == task.number }) else { return }
        tasks[index] = task
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
