import SwiftUI

struct TasksSectionView: View {
    let repo: RepoConfig
    var inspector: ProjectInspectorModel
    var onCreateTask: () -> Void
    @State private var working = false
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
                        onStatus: { newStatus in update { try await service.setStatus(repo: repo, task: task, status: newStatus) } },
                        onPriority: { newPriority in update { try await service.setPriority(repo: repo, task: task, priority: newPriority) } }
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

    private func update(_ work: @escaping () async throws -> Void) {
        guard !working else { return }
        working = true; errorMessage = nil
        Task {
            do { try await work() } catch { errorMessage = error.localizedDescription }
            working = false
        }
    }
}
