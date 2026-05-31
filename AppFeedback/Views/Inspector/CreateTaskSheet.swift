import SwiftUI

struct CreateTaskSheet: View {
    let repo: RepoConfig
    let feedbackNumbers: [Int]
    let versions: [ProjectVersion]
    var onCreated: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var prose = ""
    @State private var status: TaskStatus = .todo
    @State private var priority: TaskPriority = .med
    @State private var selectedVersionID: UUID?
    @State private var working = false
    @State private var errorMessage: String?
    private let service = TaskService()

    var body: some View {
        NavigationStack {
            Form {
                Section("Task") {
                    TextField("Title", text: $title)
                    TextField("Notes", text: $prose, axis: .vertical).lineLimit(3...8)
                }
                Section("Metadata") {
                    Picker("Status", selection: $status) { ForEach(TaskStatus.allCases, id: \.self) { Text($0.displayName).tag($0) } }
                    Picker("Priority", selection: $priority) { ForEach(TaskPriority.allCases, id: \.self) { Text($0.displayName).tag($0) } }
                    Picker("Version", selection: $selectedVersionID) {
                        Text("None").tag(UUID?.none)
                        ForEach(versions) { v in Text(v.name).tag(Optional(v.id)) }
                    }
                }
                if !feedbackNumbers.isEmpty {
                    Section("Addresses feedback") {
                        Text(feedbackNumbers.map { "#\($0)" }.joined(separator: ", "))
                            .foregroundStyle(.secondary)
                    }
                }
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            }
            .formStyle(.grouped)
            .navigationTitle("New Task")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { create() }.disabled(title.isEmpty || working)
                }
            }
        }
    }

    private func create() {
        working = true; errorMessage = nil
        let milestone = versions.first { $0.id == selectedVersionID }?.milestoneNumber
        Task {
            do {
                _ = try await service.createTask(repo: repo, title: title, prose: prose,
                    feedbackRefs: feedbackNumbers, status: status, priority: priority, milestoneNumber: milestone)
                onCreated(); dismiss()
            } catch { errorMessage = error.localizedDescription; working = false }
        }
    }
}
