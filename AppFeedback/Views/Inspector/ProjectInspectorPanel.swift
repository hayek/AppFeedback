import SwiftUI

struct ProjectInspectorPanel: View {
    let repo: RepoConfig?
    var inspector: ProjectInspectorModel
    var versionStore: VersionStore
    var canEmail: Bool
    var onCreateTask: () -> Void
    var onCreateVersion: () -> Void
    var onRelease: (ProjectVersion) -> Void

    @State private var taskToOpen: TaskItem?
    @State private var versionToOpen: ProjectVersion?
    private let taskService = TaskService()

    var body: some View {
        Group {
            if let repo {
                List {
                    tasksSection(repo: repo)
                    versionsSection(repo: repo)
                }
                .listStyle(.plain)
                .listSectionSeparator(.hidden)
                .scrollContentBackground(.hidden)
                .scrollIndicators(.hidden)
                .background(atmosphere)
                .sheet(item: $taskToOpen) { task in
                    TaskDetailView(repo: repo, task: task, inspector: inspector, versionStore: versionStore)
                }
                .sheet(item: $versionToOpen) { version in
                    NavigationStack {
                        VersionDetailView(repo: repo, version: version, inspector: inspector,
                                          versionStore: versionStore,
                                          onRelease: { versionToOpen = nil; onRelease(version) },
                                          canEmail: canEmail)
                    }
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

    // MARK: Sections

    @ViewBuilder private func tasksSection(repo: RepoConfig) -> some View {
        let tasks = inspector.filteredTasks
        Section {
            if tasks.isEmpty {
                PanelEmptyState(icon: "checklist", message: "No tasks yet.").panelRow()
            } else {
                ForEach(tasks) { task in
                    TaskCard(
                        task: task,
                        onStatus: { changeStatus(repo: repo, task: task, status: $0) },
                        onPriority: { changePriority(repo: repo, task: task, priority: $0) },
                        onOpen: { taskToOpen = task }
                    )
                    .panelRow()
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) { deleteTask(repo: repo, task: task) } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
        } header: {
            PanelSectionHeader(title: "Tasks", count: tasks.count, addLabel: "New Task", add: onCreateTask)
                .listRowSeparator(.hidden)
        }
    }

    @ViewBuilder private func versionsSection(repo: RepoConfig) -> some View {
        let versions = versionStore.versions(owner: repo.owner, repo: repo.repo)
        Section {
            if versions.isEmpty {
                PanelEmptyState(icon: "shippingbox", message: "No versions yet.").panelRow()
            } else {
                ForEach(versions) { version in
                    VersionCard(
                        name: version.name,
                        state: version.derivedState(anyTaskStarted: inspector.anyTaskStarted(versionNamed: version.name)),
                        taskCount: inspector.tasks(forVersionNamed: version.name).count,
                        action: { versionToOpen = version }
                    )
                    .panelRow()
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) { deleteVersion(repo: repo, version: version) } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
        } header: {
            PanelSectionHeader(title: "Versions", count: versions.count, addLabel: "New Version", add: onCreateVersion)
                .listRowSeparator(.hidden)
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

    private func deleteTask(repo: RepoConfig, task: TaskItem) {
        inspector.removeTask(number: task.number)
        Task { try? await taskService.deleteTask(repo: repo, task: task) }
    }

    private func deleteVersion(repo: RepoConfig, version: ProjectVersion) {
        let service = VersionService(store: versionStore)
        Task { try? await service.deleteVersion(repo: repo, version: version) }
    }
}

private extension View {
    /// Styles a List row so the card "floats": no separators, clear background, tight insets.
    func panelRow() -> some View {
        self
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 5, leading: 12, bottom: 5, trailing: 12))
    }
}
