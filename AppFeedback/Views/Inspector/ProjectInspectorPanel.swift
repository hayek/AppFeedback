import SwiftUI

struct ProjectInspectorPanel: View {
    let repo: RepoConfig?
    var inspector: ProjectInspectorModel
    var versionStore: VersionStore
    var canEmail: Bool
    var onCreateTask: () -> Void
    var onCreateVersion: () -> Void
    var onRelease: (ProjectVersion) -> Void
    var onDeleteTask: (TaskItem) -> Void
    var onOpenFeedback: (Int) -> Void

    @State private var taskToOpen: TaskItem?
    @State private var versionToOpen: ProjectVersion?
    @State private var taskToDelete: TaskItem?
    @State private var versionToDelete: ProjectVersion?
    private let taskService = TaskService()

    var body: some View {
        Group {
            if let repo {
                List {
                    header(title: "Tasks", count: inspector.filteredTasks.count,
                           addLabel: "New Task", add: onCreateTask, topPad: 4)
                    taskRows(repo: repo)

                    header(title: "Versions", count: versionStore.versions(owner: repo.owner, repo: repo.repo).count,
                           addLabel: "New Version", add: onCreateVersion, topPad: 22)
                    versionRows(repo: repo)
                }
                .listStyle(.plain)
                .environment(\.defaultMinListRowHeight, 0)
                .scrollContentBackground(.hidden)
                .scrollIndicators(.hidden)
                #if os(iOS)
                .contentMargins(.top, 16, for: .scrollContent)
                #endif
                .background(atmosphere)
                .sheet(item: $taskToOpen) { task in
                    TaskDetailView(repo: repo, task: task, inspector: inspector, versionStore: versionStore,
                                   onDelete: { taskToOpen = nil; onDeleteTask(task) },
                                   onOpenFeedback: onOpenFeedback)
                }
                .sheet(item: $versionToOpen) { version in
                    NavigationStack {
                        VersionDetailView(repo: repo, version: version, inspector: inspector,
                                          versionStore: versionStore,
                                          onRelease: { versionToOpen = nil; onRelease(version) },
                                          onDeleteTask: onDeleteTask,
                                          onOpenFeedback: onOpenFeedback,
                                          canEmail: canEmail)
                    }
                }
                .confirmationDialog(
                    taskToDelete.map { "Delete task #\($0.number)?" } ?? "Delete task?",
                    isPresented: Binding(get: { taskToDelete != nil }, set: { if !$0 { taskToDelete = nil } }),
                    titleVisibility: .visible,
                    presenting: taskToDelete
                ) { task in
                    Button("Delete Task", role: .destructive) { onDeleteTask(task) }
                } message: { _ in
                    Text("This permanently deletes the issue on GitHub.")
                }
                .confirmationDialog(
                    versionToDelete.map { "Delete version \($0.name)?" } ?? "Delete version?",
                    isPresented: Binding(get: { versionToDelete != nil }, set: { if !$0 { versionToDelete = nil } }),
                    titleVisibility: .visible,
                    presenting: versionToDelete
                ) { version in
                    Button("Delete Version", role: .destructive) { deleteVersion(repo: repo, version: version) }
                } message: { _ in
                    Text("This removes the milestone on GitHub and the version here. Tasks are not deleted.")
                }
            } else {
                ContentUnavailableView {
                    Label("No project selected", systemImage: "sidebar.right")
                } description: {
                    Text("Pick a project in the sidebar to see its tasks and versions.")
                }
                .background(atmosphere)
            }
        }
    }

    // MARK: Rows

    private func header(title: String, count: Int, addLabel: String, add: @escaping () -> Void, topPad: CGFloat) -> some View {
        PanelSectionHeader(title: title, count: count, addLabel: addLabel, add: add)
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: topPad, leading: 12, bottom: 8, trailing: 12))
    }

    @ViewBuilder private func taskRows(repo: RepoConfig) -> some View {
        let tasks = inspector.filteredTasks
        if tasks.isEmpty {
            PanelEmptyState(icon: "checklist", message: "No tasks yet.").cardRow()
        } else {
            ForEach(tasks) { task in
                TaskCard(
                    task: task,
                    onStatus: { changeStatus(repo: repo, task: task, status: $0) },
                    onPriority: { changePriority(repo: repo, task: task, priority: $0) },
                    onOpen: { taskToOpen = task }
                )
                .cardRow()
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) { taskToDelete = task } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
    }

    @ViewBuilder private func versionRows(repo: RepoConfig) -> some View {
        let versions = versionStore.versions(owner: repo.owner, repo: repo.repo)
        if versions.isEmpty {
            PanelEmptyState(icon: "shippingbox", message: "No versions yet.").cardRow()
        } else {
            ForEach(versions) { version in
                VersionCard(
                    name: version.name,
                    state: version.derivedState(anyTaskStarted: inspector.anyTaskStarted(versionNamed: version.name)),
                    taskCount: inspector.tasks(forVersionNamed: version.name).count,
                    action: { versionToOpen = version }
                )
                .cardRow()
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) { versionToDelete = version } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
    }

    private var atmosphere: some View {
        LinearGradient(colors: [Color.primary.opacity(0.04), .clear], startPoint: .top, endPoint: .center)
            .ignoresSafeArea()
    }

    // MARK: Mutations (optimistic + background write)

    private func changeStatus(repo: RepoConfig, task: TaskItem, status: TaskStatus) {
        let previous = inspector.applyOptimistic(number: task.number, status: status)
        Task {
            do { try await taskService.setStatus(repo: repo, task: task, status: status) }
            catch { if let previous { inspector.restore(previous) } }
        }
    }

    private func changePriority(repo: RepoConfig, task: TaskItem, priority: TaskPriority) {
        let previous = inspector.applyOptimistic(number: task.number, priority: priority)
        Task {
            do { try await taskService.setPriority(repo: repo, task: task, priority: priority) }
            catch { if let previous { inspector.restore(previous) } }
        }
    }

    private func deleteVersion(repo: RepoConfig, version: ProjectVersion) {
        let service = VersionService(store: versionStore)
        Task { try? await service.deleteVersion(repo: repo, version: version) }
    }
}

private extension View {
    /// A card row: full width, no separators, clear background, tight side margins.
    func cardRow() -> some View {
        self
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 5, leading: 12, bottom: 5, trailing: 12))
    }
}
