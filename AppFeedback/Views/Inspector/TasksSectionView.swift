import SwiftUI

struct TasksSectionView: View {
    let repo: RepoConfig
    var inspector: ProjectInspectorModel
    @State private var working = false
    @State private var errorMessage: String?
    private let service = TaskService()

    var body: some View {
        if inspector.filteredTasks.isEmpty {
            Text("No tasks yet. Select feedbacks and choose \u{201C}Create Task.\u{201D}")
                .font(.callout).foregroundStyle(.secondary)
        } else {
            ForEach(inspector.filteredTasks) { task in
                TaskRow(task: task,
                        onStatus: { newStatus in update { try await service.setStatus(repo: repo, task: task, status: newStatus) } },
                        onPriority: { newPriority in update { try await service.setPriority(repo: repo, task: task, priority: newPriority) } })
            }
        }
        if let errorMessage {
            Text(errorMessage).font(.footnote).foregroundStyle(.red)
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

private struct TaskRow: View {
    let task: TaskItem
    var onStatus: (TaskStatus) -> Void
    var onPriority: (TaskPriority) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("#\(task.number)").font(.caption.monospaced()).foregroundStyle(.secondary)
                Text(task.title).font(.callout).lineLimit(2)
            }
            HStack(spacing: 8) {
                Menu(task.status.displayName) {
                    ForEach(TaskStatus.allCases, id: \.self) { s in Button(s.displayName) { onStatus(s) } }
                }.font(.caption)
                Menu(task.priority.displayName) {
                    ForEach(TaskPriority.allCases, id: \.self) { p in Button(p.displayName) { onPriority(p) } }
                }.font(.caption)
                if !task.feedbackRefs.isEmpty {
                    Text(task.feedbackRefs.map { "#\($0)" }.joined(separator: " "))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }
}
