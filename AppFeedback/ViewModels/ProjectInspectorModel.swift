import Foundation
import Observation

@Observable @MainActor
final class ProjectInspectorModel {
    private(set) var tasks: [TaskItem] = []
    var statusFilter: TaskStatus? = nil

    func setTasks(_ tasks: [TaskItem]) { self.tasks = tasks }

    var filteredTasks: [TaskItem] {
        guard let statusFilter else { return tasks }
        return tasks.filter { ($0.status == statusFilter && !$0.isClosed) || (statusFilter == .done && $0.isCompleted) }
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
