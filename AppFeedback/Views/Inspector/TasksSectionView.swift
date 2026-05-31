import SwiftUI

struct TasksSectionView: View {
    let repo: RepoConfig
    var inspector: ProjectInspectorModel
    var onCreateTask: () -> Void
    @State private var errorMessage: String?
    private let service = TaskService()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PanelAddButton(title: "New Task", action: onCreateTask)

            if inspector.filteredTasks.isEmpty {
                PanelEmptyState(icon: "checklist", message: "No tasks yet.")
            } else {
                ForEach(inspector.filteredTasks) { task in
                    TaskCard(
                        task: task,
                        onStatus: { newStatus in
                            let previous = inspector.applyOptimistic(number: task.number, status: newStatus)
                            commit(revert: previous) { try await service.setStatus(repo: repo, task: task, status: newStatus) }
                        },
                        onPriority: { newPriority in
                            let previous = inspector.applyOptimistic(number: task.number, priority: newPriority)
                            commit(revert: previous) { try await service.setPriority(repo: repo, task: task, priority: newPriority) }
                        }
                    )
                }
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.leading, 2)
            }
        }
    }

    /// Runs the GitHub write that backs an already-applied optimistic change. On failure, rolls the
    /// UI back to `previous` and surfaces the error so the change never silently disappears.
    private func commit(revert previous: TaskItem?, _ work: @escaping () async throws -> Void) {
        errorMessage = nil
        Task {
            do {
                try await work()
            } catch {
                if let previous { inspector.restore(previous) }
                errorMessage = error.localizedDescription
            }
        }
    }
}
