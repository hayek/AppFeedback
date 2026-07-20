import SwiftUI

struct ProjectInspectorPanel: View {
    let repo: ProductConfig?
    var inspector: ProjectInspectorModel
    var versionStore: VersionStore
    var canEmail: Bool
    var onCreateTask: () -> Void
    var onCreateVersion: () -> Void
    var onRelease: (ProjectVersion) -> Void
    /// Renames a version end-to-end (GitHub milestone → local record → cascade). Throws so the
    /// detail sheet can hold itself open and show why it failed. The repo is threaded through here
    /// (rather than re-resolved from `selection` upstream) because this panel already has it as a
    /// non-optional `let` — there is nothing to fall back to if it were missing.
    var onRename: (ProductConfig, ProjectVersion, String) async throws -> Void
    var onDeleteTask: (TaskItem) -> Void
    var onOpenFeedback: (Int) -> Void
    var onRetryCreation: (UUID) -> Void = { _ in }
    var onDismissCreation: (UUID) -> Void = { _ in }
    var versionCreations: CreationStatusTracker
    var onRetryVersion: (UUID) -> Void = { _ in }
    var onDismissVersion: (UUID) -> Void = { _ in }
    /// Pull-to-refresh: reloads the repo's tasks (and versions reflect their synced state).
    var onRefresh: () async -> Void = {}

    @State private var taskToOpen: TaskItem?
    @State private var versionToOpen: ProjectVersion?
    @State private var taskToDelete: TaskItem?
    @State private var versionToDelete: ProjectVersion?
    private let taskService = TaskService()

    @Environment(FeedbackTriageCoordinator.self) private var triageCoordinator

    var body: some View {
        Group {
            if let repo {
                // Row insert/remove animate via List's own animation (driven by `withAnimation`
                // at the mutation sites); the badge fades via a value-animation on the card. The
                // key is NOT to put custom `.transition`s on List rows — that suppresses List's
                // built-in animation.
                // Chips/buttons use `.accentColor` for interactivity — intentionally unlike
                // RepoSectionView's sidebar dot, which falls back to `.secondary` as a neutral marker.
                let accent: Color = repo.colorHex.map(Color.init(hex:)) ?? .accentColor
                List {
                    header(title: "Tasks", count: taskRowItems.count,
                           addLabel: "New Task", add: onCreateTask, topPad: 4)
                    filterRow { TaskFilterBar(inspector: inspector, accent: accent) }
                    taskRows(repo: repo)

                    header(title: "Versions", count: filteredVersions(repo: repo).count,
                           addLabel: "New Version", add: onCreateVersion, topPad: 22)
                    filterRow { VersionFilterBar(inspector: inspector, accent: accent) }
                    versionRows(repo: repo)
                }
                .listStyle(.plain)
                .environment(\.defaultMinListRowHeight, 0)
                .scrollContentBackground(.hidden)
                .scrollIndicators(.hidden)
                .refreshable { await onRefresh() }
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
                                          onRename: { newName in try await onRename(repo, version, newName) },
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

    @ViewBuilder
    private func filterRow<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 4, trailing: 0))
    }

    /// Real tasks and not-yet-reloaded creation placeholders, merged and sorted together so a
    /// placeholder sits where its real card will land — no jump at hand-off. A real task that a
    /// just-created creation still tracks carries that creation's badge.
    private var taskRowItems: [InspectorTaskRow] {
        let tasks = inspector.filteredTasks
        // Presence is judged against the full task set (not the filtered one) so a creation's
        // hand-off to its real card is detected even if a status filter would hide that task.
        let present = Set(inspector.tasks.map(\.number))
        var rows: [InspectorTaskRow] = tasks.map {
            .task($0, badge: inspector.creationBadge(forTaskNumber: $0.number))
        }
        rows += inspector.pendingCreations(loadedTaskNumbers: present).map(InspectorTaskRow.pending)
        return rows.sorted { $0.sortKey < $1.sortKey }
    }

    @ViewBuilder private func taskRows(repo: ProductConfig) -> some View {
        let rows = taskRowItems
        let aiCreatedTaskNumbers = triageCoordinator.aiCreatedTaskNumbers(owner: repo.owner, repo: repo.repo)
        // Keep the ForEach unconditional (no enclosing if/else) so List sees a stable ForEach and
        // animates row insert/remove; the empty state is a separate trailing row.
        ForEach(rows) { row in
            switch row {
            case .task(let task, let badge):
                TaskCard(
                    task: task,
                    onStatus: { changeStatus(repo: repo, task: task, status: $0) },
                    onPriority: { changePriority(repo: repo, task: task, priority: $0) },
                    onOpen: { taskToOpen = task },
                    creationBadge: badge,
                    isAICreated: aiCreatedTaskNumbers.contains(task.number)
                )
                .cardRow()
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) { taskToDelete = task } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            case .pending(let creation):
                PendingTaskCard(
                    creation: creation,
                    onRetry: { onRetryCreation(creation.id) },
                    onDismiss: { onDismissCreation(creation.id) }
                )
                .cardRow()
            }
        }
        if rows.isEmpty {
            if inspector.taskFilters.isActive && !inspector.tasks.isEmpty {
                PanelFilteredEmptyState(message: "No tasks match") { inspector.clearTaskFilters() }.cardRow()
            } else {
                PanelEmptyState(icon: "checklist", message: "No tasks yet.").cardRow()
            }
        }
    }

    /// All versions for the repo, narrowed by the active version filters. Called twice per render
    /// (header count + rows); the work is O(versions × tasks) but negligible at sidebar scale.
    private func filteredVersions(repo: ProductConfig) -> [ProjectVersion] {
        versionStore.versions(owner: repo.owner, repo: repo.repo).filter { version in
            inspector.versionMatches(
                name: version.name,
                releaseTitle: version.releaseTitle,
                state: version.derivedState(anyTaskStarted: inspector.anyTaskStarted(versionNamed: version.name))
            )
        }
    }

    @ViewBuilder private func versionRows(repo: ProductConfig) -> some View {
        let total = versionStore.versions(owner: repo.owner, repo: repo.repo).count
        let versions = filteredVersions(repo: repo)
        ForEach(versions) { version in
            VersionCard(
                name: version.name,
                state: version.derivedState(anyTaskStarted: inspector.anyTaskStarted(versionNamed: version.name)),
                taskCount: inspector.tasks(forVersionNamed: version.name).count,
                creationBadge: versionCreations.status(version.id),
                onRetry: { onRetryVersion(version.id) },
                onDismiss: { onDismissVersion(version.id) },
                action: { versionToOpen = version }
            )
            .cardRow()
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive) { versionToDelete = version } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
        if versions.isEmpty {
            if inspector.versionFilters.isActive && total > 0 {
                PanelFilteredEmptyState(message: "No versions match") { inspector.clearVersionFilters() }.cardRow()
            } else {
                PanelEmptyState(icon: "shippingbox", message: "No versions yet.").cardRow()
            }
        }
    }

    private var atmosphere: some View {
        LinearGradient(colors: [Color.primary.opacity(0.04), .clear], startPoint: .top, endPoint: .center)
            .ignoresSafeArea()
    }

    // MARK: Mutations (optimistic + background write)

    private func changeStatus(repo: ProductConfig, task: TaskItem, status: TaskStatus) {
        let previous = inspector.applyOptimistic(number: task.number, status: status)
        Task {
            do { try await taskService.setStatus(repo: repo, task: task, status: status) }
            catch { if let previous { inspector.restore(previous) } }
        }
    }

    private func changePriority(repo: ProductConfig, task: TaskItem, priority: TaskPriority) {
        let previous = inspector.applyOptimistic(number: task.number, priority: priority)
        Task {
            do { try await taskService.setPriority(repo: repo, task: task, priority: priority) }
            catch { if let previous { inspector.restore(previous) } }
        }
    }

    private func deleteVersion(repo: ProductConfig, version: ProjectVersion) {
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

/// One row in the Tasks section: either a real task (optionally wearing a just-created badge) or
/// a placeholder for a creation whose issue hasn't reloaded yet. Both sort by the same key so a
/// placeholder occupies the slot its real card will, avoiding a jump at hand-off.
private enum InspectorTaskRow: Identifiable {
    case task(TaskItem, badge: CreationPhase?)
    case pending(TaskCreation)

    var id: String {
        switch self {
        case .task(let task, _): return "task-\(task.number)"
        case .pending(let creation): return "pending-\(creation.id)"
        }
    }

    /// (priority rank, pending-flag, tiebreak). Within a priority, real tasks (flag 0, by issue
    /// number) come first and placeholders (flag 1, by creation order) after — so a placeholder
    /// sits where its brand-new (highest-numbered) issue will land, and several placeholders keep
    /// a stable oldest-first order. Hand-off to the real card causes no reorder.
    var sortKey: (Int, Int, Int) {
        switch self {
        case .task(let task, _): return (task.priority.sortRank, 0, task.number)
        case .pending(let creation): return (creation.draft.priority.sortRank, 1, creation.sequence)
        }
    }
}
