import SwiftUI
import SwiftData

@MainActor
struct RootView: View {
    var store: RepoStore
    var seenStore: SeenIssueStore
    var cacheContext: ModelContext
    var versionStore: VersionStore

    init(store: RepoStore, seenStore: SeenIssueStore, cacheContext: ModelContext, versionStore: VersionStore) {
        self.store = store
        self.seenStore = seenStore
        self.cacheContext = cacheContext
        self.versionStore = versionStore
        // Seed the selection so the iPhone opens to the detail (feedback) rather than the sidebar.
        _selection = State(initialValue: store.repos.first.map { SidebarSelection.allIssues(repoId: $0.id) })
    }

    @State private var loaders: [UUID: IssueLoader] = [:]
    @State private var selection: SidebarSelection?
    @State private var viewModel = IssueListViewModel()
    @State private var summaryVM: UnreadSummaryViewModel?
    @State private var showSettings = false
    @State private var showAddRepo = false
    @State private var showInspector = true
    @State private var inspector = ProjectInspectorModel()
    @State private var versionToRelease: ProjectVersion?
    @State private var taskFromFeedback: TaskItem?
    /// Serializes feedback-ref writes per task issue so two rapid attach/detach gestures on the
    /// same task can't race to a PATCH that lands out of order and drops a ref.
    @State private var refWriteChain: [Int: Task<Void, Never>] = [:]
    /// Surfaces a failed attach/detach write so the optimistic tag doesn't just silently revert.
    @State private var taskWriteError: String?
    @State private var showCreateVersion = false
    @State private var showCreateTask = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var preferredColumn: NavigationSplitViewColumn = .detail
    @Environment(\.scenePhase) private var scenePhase
    @Environment(ActivityLog.self) private var activityLog
    @Environment(MailAccountStore.self) private var mailAccountStore
    @Environment(MailSettingsStore.self) private var mailSettingsStore
    @Environment(MailThreadStore.self) private var mailThreadStore
    @Environment(OutboundSendTracker.self) private var outboundTracker
    @Environment(OutboundFailureStore.self) private var outboundFailures
    @Environment(MailToGitHubMirrorHolder.self) private var mirrorHolder: MailToGitHubMirrorHolder?
    @Environment(IntelligenceSettings.self) private var intelligenceSettings
    @Environment(IntelligenceService.self) private var intelligenceService
    @Environment(NotificationSettings.self) private var notificationSettings
    @Environment(NotificationRouter.self) private var notificationRouter
    @Environment(\.notificationService) private var notificationService
    @Environment(\.mailSyncCoordinatorRegistry) private var coordinatorRegistry: MailSyncCoordinatorRegistry?
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif

    /// Legacy single-Bool key — read-once for migration, then deleted.
    private static let legacyBacklogSnapshotKey = "appfeedback.notifications.backlogSnapshotted"
    /// New per-repo set key: stores Set<String> of "owner/repo" strings.
    private static let snapshottedReposKey = "appfeedback.notifications.snapshottedRepos"

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility, preferredCompactColumn: $preferredColumn) {
            SidebarView(store: store, loaders: loaders, selection: $selection, onAddRepo: { showAddRepo = true })
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            #if os(macOS)
                            openWindow(id: "settings")
                            #else
                            showSettings = true
                            #endif
                        } label: {
                            Image(systemName: "gear")
                        }
                    }
                }
        } detail: {
            if let selection {
                if let summaryVM {
                    let repo = store.repos.first(where: { $0.id == selection.repoId })
                    let owner = repo?.owner ?? ""
                    let name = repo?.repo ?? ""
                    IssueListView(
                        viewModel: viewModel,
                        loader: loaders[selection.repoId],
                        allApps: allApps(for: selection.repoId),
                        onRefresh: {
                            async let mailPoll: Void = coordinatorRegistry?.pollNow() ?? ()
                            if let repo, let token = await KeychainService.load(for: repo) {
                                // Explicit refresh does a full reconcile so deletions upstream are
                                // detected and stale phantom issues are pruned from the cache.
                                await loaders[selection.repoId]?.load(token: token, fullReconcile: true)
                            }
                            await mailPoll
                        },
                        onDropTask: { attachTask(taskNumber: $0, toFeedback: $1) },
                        attachedTasksByFeedback: attachedTasksByFeedback,
                        onOpenTask: { taskFromFeedback = $0 },
                        onRemoveTaskFromFeedback: { detachTask(taskNumber: $0, fromFeedback: $1) },
                        repoOwner: owner,
                        repoName: name,
                        appColorOverrides: store.appColors[selection.repoId] ?? [:],
                        summaryVM: summaryVM,
                        summaryCollapseKey: "\(owner)/\(name)"
                    )
                    #if os(iOS)
                    .navigationTitle(navigationTitle(for: selection))
                    .navigationBarTitleDisplayMode(.inline)
                    #endif
                    .toolbar {
                        ToolbarItem(placement: .primaryAction) {
                            Button { showInspector.toggle() } label: { Image(systemName: "sidebar.trailing") }
                                .help("Toggle Tasks & Versions")
                        }
                    }
                    .inspector(isPresented: $showInspector) {
                        inspectorPanel(for: selection)
                    }
                } else {
                    ProgressView()
                }
            } else {
                ContentUnavailableView {
                    Label("No repo selected", systemImage: "tray")
                } description: {
                    Text("Add a repo in Settings, then select it from the sidebar.")
                } actions: {
                    Button("+ Add Repo") { showAddRepo = true }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(store: store)
        }
        .sheet(isPresented: $showAddRepo) {
            AddEditRepoView(store: store)
        }
        .alert("Couldn't update task", isPresented: Binding(
            get: { taskWriteError != nil },
            set: { if !$0 { taskWriteError = nil } }
        )) {
            Button("OK", role: .cancel) { taskWriteError = nil }
        } message: {
            Text(taskWriteError ?? "")
        }
        .sheet(isPresented: $showCreateTask) {
            if let repo = store.repos.first(where: { $0.id == selection?.repoId }) {
                CreateTaskSheet(repo: repo,
                    versions: versionStore.versions(owner: repo.owner, repo: repo.repo),
                    onCreated: { Task { await refreshSelectedRepo() } })
            }
        }
        .sheet(isPresented: $showCreateVersion) {
            if let repo = store.repos.first(where: { $0.id == selection?.repoId }) {
                NewVersionSheet(repo: repo, versionStore: versionStore, onCreated: {})
            }
        }
        .sheet(item: $taskFromFeedback) { task in
            if let repo = store.repos.first(where: { $0.id == selection?.repoId }) {
                TaskDetailView(repo: repo, task: task, inspector: inspector, versionStore: versionStore,
                               onDelete: { taskFromFeedback = nil; deleteTask(task) },
                               onOpenFeedback: { openFeedback($0) })
            }
        }
        .sheet(item: $versionToRelease) { version in
            if let repo = store.repos.first(where: { $0.id == selection?.repoId }) {
                let recipients = ReleaseRecipientCalculator.recipients(
                    versionNamed: version.name, tasks: viewModel.tasks, feedback: viewModel.allIssues)
                ReleaseRecipientsSheet(
                    repo: repo, version: version, recipients: recipients,
                    alreadySent: versionStore.alreadyNotifiedEmails(owner: repo.owner, repo: repo.repo, versionName: version.name),
                    appName: repo.displayName,
                    makeService: { ReleaseNotificationService(versionStore: versionStore, deps: releaseDeps()) },
                    feedback: viewModel.allIssues,
                    onPublish: {
                        let service = VersionService(store: versionStore)
                        let tag = version.releaseTag ?? "v\(version.name)"
                        _ = try? await service.release(repo: repo, version: version, tag: tag, target: nil,
                            publishRelease: true, now: Date())
                    })
            }
        }
        .onChange(of: selection) { _, newValue in
            guard let newValue else { return }
            updateViewModel(for: newValue)
        }
        .onChange(of: selectedLoadedSignature) { _, _ in
            if let selection { updateViewModel(for: selection) }
        }
        .onChange(of: store.repos) { _, newRepos in
            syncLoaders(repos: newRepos)
            autoSelectIfNeeded(repos: newRepos)
        }
        .onChange(of: store.hiddenApps) { _, _ in
            if let selection { viewModel.hiddenApps = store.hiddenAppsFor(selection.repoId) }
        }
        .task {
            if summaryVM == nil {
                summaryVM = UnreadSummaryViewModel(provider: intelligenceService)
            }
            viewModel.attachIntelligence(
                provider: intelligenceService,
                settings: intelligenceSettings,
                cacheContext: cacheContext
            )
            // syncLoaders dispatches a load for each newly-added repo, so a separate
            // loadAllRepos here would race the syncLoaders task and double-fetch. On first
            // launch every repo is newly-added, so syncLoaders alone covers it. Re-fetching
            // existing repos happens via pull-to-refresh, scenePhase, or background drivers.
            syncLoaders(repos: store.repos)
            autoSelectIfNeeded(repos: store.repos)
            Task.detached(priority: .utility) { @MainActor in
                intelligenceService.recomputeAvailability()
            }
        }
        .onChange(of: intelligenceSettings.targetLanguageCode) { _, _ in
            viewModel.invalidateTranslations()
            viewModel.startTranslationsIfNeeded()
        }
        .onChange(of: intelligenceSettings.translationEnabled) { _, enabled in
            if enabled {
                viewModel.startTranslationsIfNeeded()
            } else {
                viewModel.invalidateTranslations()
            }
        }
        // MARK: Notification tap routing
        .onChange(of: notificationRouter.pendingIssueKey) { _, _ in
            guard let key = notificationRouter.consume() else { return }
            Task { await handleNotificationTap(key: key) }
        }
        // MARK: First-load backlog snapshot
        .onChange(of: repoGroupSignature) { _, _ in
            maybeSnapshotBacklog()
        }
        .onChange(of: notificationSettings.isEnabled) { _, isOn in
            if isOn { maybeSnapshotBacklog() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { retryStuckLoaders() }
        }
        .task {
            for await _ in NotificationCenter.cloudKitImportSucceeded {
                retryStuckLoaders()
            }
        }
    }

    #if os(iOS)
    private func navigationTitle(for selection: SidebarSelection) -> String {
        store.repos.first(where: { $0.id == selection.repoId })?.displayName ?? "Feedback"
    }
    #endif

    private func allApps(for repoId: UUID) -> [String] {
        guard let loader = loaders[repoId],
              case .loaded(let issues, _) = loader.state else { return [] }
        return Array(Set(issues.compactMap(\.appName))).sorted()
    }

    @ViewBuilder
    private func inspectorPanel(for selection: SidebarSelection) -> some View {
        ProjectInspectorPanel(
            repo: store.repos.first(where: { $0.id == selection.repoId }),
            inspector: inspector,
            versionStore: versionStore,
            canEmail: mailAccountStore.defaultSender != nil,
            onCreateTask: { showCreateTask = true },
            onCreateVersion: { showCreateVersion = true },
            onRelease: { startRelease($0) },
            onDeleteTask: { deleteTask($0) },
            onOpenFeedback: { openFeedback($0) }
        )
        .inspectorColumnWidth(min: 260, ideal: 320, max: 480)
    }

    private func updateViewModel(for selection: SidebarSelection) {
        guard let loader = loaders[selection.repoId],
              case .loaded(let issues, _) = loader.state else { return }
        let owner = store.repos.first(where: { $0.id == selection.repoId })?.owner ?? ""
        let repoName = store.repos.first(where: { $0.id == selection.repoId })?.repo  ?? ""
        viewModel.hiddenApps = store.hiddenAppsFor(selection.repoId)
        viewModel.attachSeenStore(seenStore, owner: owner, repo: repoName)
        viewModel.applyLoaded(issues)
        inspector.setTasks(viewModel.tasks)
        viewModel.clearFilters()
        viewModel.appFilter = []
        viewModel.allowsAppFilter = true
    }

    private var selectedLoadedSignature: String {
        guard let selection,
              let loader = loaders[selection.repoId],
              case .loaded(let issues, let date) = loader.state else { return "" }
        return "\(selection.repoId)-\(issues.count)-\(date.timeIntervalSince1970)"
    }

    private func autoSelectIfNeeded(repos: [RepoConfig]) {
        if selection == nil, let first = repos.first {
            selection = .allIssues(repoId: first.id)
            return
        }
        if let current = selection, !repos.contains(where: { $0.id == current.repoId }) {
            selection = repos.first.map { .allIssues(repoId: $0.id) }
        }
    }

    private func syncLoaders(repos: [RepoConfig]) {
        var newlyAdded: [RepoConfig] = []
        for repo in repos where loaders[repo.id] == nil {
            loaders[repo.id] = IssueLoader(
                config: repo,
                activityLog: activityLog,
                cacheContext: cacheContext
            )
            newlyAdded.append(repo)
        }
        let ids = Set(repos.map(\.id))
        loaders = loaders.filter { ids.contains($0.key) }
        if !newlyAdded.isEmpty {
            Task { await loadRepos(newlyAdded) }
        }
    }

    private func releaseDeps() -> ReleaseNotificationService.Dependencies {
        ReleaseNotificationService.Dependencies(
            accountStore: mailAccountStore,
            settingsStore: mailSettingsStore,
            threadStore: mailThreadStore,
            outboundTracker: outboundTracker,
            outboundFailures: outboundFailures,
            sender: MailSender(),
            activityLog: activityLog,
            mirror: mirrorHolder?.mirror
        )
    }

    private func loadAllRepos() async {
        await loadRepos(store.repos)
    }

    /// Opens the release recipients flow for a version. On iOS the inspector is presented as a
    /// sheet, so it's dismissed first to let the recipients sheet present cleanly.
    private func startRelease(_ version: ProjectVersion) {
        #if os(iOS)
        showInspector = false
        #endif
        versionToRelease = version
    }

    /// Tasks attached to each feedback (by feedback number) — drives the clickable task tags.
    private var attachedTasksByFeedback: [Int: [TaskItem]] {
        var map: [Int: [TaskItem]] = [:]
        for task in inspector.tasks {
            for ref in task.feedbackRefs { map[ref, default: []].append(task) }
        }
        return map
    }

    /// Attaches a task to a feedback (drag a task card onto a feedback row): adds the feedback's
    /// number to the task's refs, optimistically, then writes to GitHub.
    private func attachTask(taskNumber: Int, toFeedback feedbackNumber: Int) {
        guard let repo = store.repos.first(where: { $0.id == selection?.repoId }),
              let task = inspector.task(number: taskNumber),
              !task.feedbackRefs.contains(feedbackNumber) else { return }
        setTaskRefs(repo: repo, task: task, refs: (task.feedbackRefs + [feedbackNumber]).sorted())
    }

    /// Detaches a task from a feedback (tap the × on a task tag): removes the feedback's number
    /// from the task's refs, optimistically, then writes to GitHub.
    private func detachTask(taskNumber: Int, fromFeedback feedbackNumber: Int) {
        guard let repo = store.repos.first(where: { $0.id == selection?.repoId }),
              let task = inspector.task(number: taskNumber),
              task.feedbackRefs.contains(feedbackNumber) else { return }
        setTaskRefs(repo: repo, task: task, refs: task.feedbackRefs.filter { $0 != feedbackNumber })
    }

    /// Optimistically updates a task's feedback refs (recorded as a pending override so a stale
    /// reload can't clobber it), writes to GitHub, then refreshes so the persisted refs flow back
    /// in. The override survives reloads and self-clears once GitHub's returned refs match — the
    /// loader serves cached/incremental state that lags the write, so an immediate reload alone
    /// would otherwise revert the attach.
    private func setTaskRefs(repo: RepoConfig, task: TaskItem, refs: [Int]) {
        let previous = inspector.setPendingRefs(number: task.number, refs: refs)
        let prior = refWriteChain[task.number]
        let job = Task {
            await prior?.value          // serialize writes to this task issue (avoid out-of-order PATCH)
            do {
                try await TaskService().setFeedbackRefs(repo: repo, task: task, refs: refs)
                await refreshSelectedRepo()
            } catch {
                if let previous { inspector.revertPending(number: task.number, to: previous) }
                if (error as? GitHubIssueWriter.WriteError)?.isNotFound == true {
                    // The task issue no longer exists on GitHub — drop the phantom from the list/cache.
                    inspector.removeTask(number: task.number)
                    loaders[repo.id]?.purgeFromCache(number: task.number)
                } else {
                    taskWriteError = "Task #\(task.number): \(error.localizedDescription)"
                }
            }
        }
        refWriteChain[task.number] = job
    }

    /// Deletes a task issue: optimistic removal, GitHub delete, then purge the cache so it doesn't
    /// reappear on the next launch (the incremental fetch never reports deletions). On failure,
    /// surface the error and refresh — it wasn't actually deleted.
    private func deleteTask(_ task: TaskItem) {
        guard let repo = store.repos.first(where: { $0.id == selection?.repoId }) else { return }
        inspector.removeTask(number: task.number)
        Task {
            do {
                try await TaskService().deleteTask(repo: repo, task: task)
                loaders[repo.id]?.purgeFromCache(number: task.number)
            } catch {
                if (error as? GitHubIssueWriter.WriteError)?.isNotFound == true {
                    // Already deleted on GitHub (a stale phantom) — purge it so it stops coming back.
                    loaders[repo.id]?.purgeFromCache(number: task.number)
                } else {
                    taskWriteError = "Couldn't delete task #\(task.number): \(error.localizedDescription)"
                    await refreshSelectedRepo()   // it wasn't deleted — bring it back
                }
            }
        }
    }

    /// Reloads the currently-selected repo so a freshly-created task issue appears.
    /// Mirrors the `IssueListView(onRefresh:)` closure: load the token, then `load`.
    private func refreshSelectedRepo() async {
        guard let selection,
              let repo = store.repos.first(where: { $0.id == selection.repoId }),
              let token = await KeychainService.load(for: repo) else { return }
        await loaders[selection.repoId]?.load(token: token)
    }

    private func loadRepos(_ repos: [RepoConfig]) async {
        await withTaskGroup(of: Void.self) { group in
            for repo in repos {
                guard let loader = loaders[repo.id] else { continue }
                group.addTask {
                    // iCloud Keychain may not have synced this token yet on a fresh device;
                    // one short retry catches that without blocking the happy path.
                    for attempt in 0..<2 {
                        if attempt > 0 { try? await Task.sleep(for: .seconds(2)) }
                        if let token = await KeychainService.load(for: repo) {
                            await loader.load(token: token)
                            return
                        }
                    }
                }
            }
        }
    }

    private func retryStuckLoaders() {
        let stuck = store.repos.filter { repo in
            guard let loader = loaders[repo.id] else { return false }
            switch loader.state {
            case .idle, .failed: return true
            case .loading, .loaded: return false
            }
        }
        guard !stuck.isEmpty else { return }
        Task { await loadRepos(stuck) }
    }

    // MARK: - Notification Tap Routing

    /// All currently-loaded (owner, repo, issues) groups across every repo.
    private var allLoadedRepoGroups: [NotificationService.RepoIssues] {
        store.repos.compactMap { repo -> NotificationService.RepoIssues? in
            guard let loader = loaders[repo.id],
                  case .loaded(let issues, _) = loader.state else { return nil }
            return (owner: repo.owner, repo: repo.repo, issues: issues)
        }
    }

    /// Find a FeedbackIssue matching `"owner/repo#number"` across all loaded loaders.
    private func findIssue(for key: String) -> (repoId: UUID, issue: FeedbackIssue)? {
        // Key format: owner/repo#number
        let parts = key.split(separator: "#", maxSplits: 1)
        guard parts.count == 2,
              let number = Int(parts[1]) else { return nil }
        let ownerRepo = String(parts[0]) // "owner/repo"

        for repo in store.repos where "\(repo.owner)/\(repo.repo)" == ownerRepo {
            if let loader = loaders[repo.id],
               case .loaded(let issues, _) = loader.state,
               let issue = issues.first(where: { $0.number == number }) {
                return (repo.id, issue)
            }
        }
        return nil
    }

    private func handleNotificationTap(key: String) async {
        // Try immediate lookup
        if let match = findIssue(for: key) {
            selectIssue(repoId: match.repoId, issue: match.issue)
            return
        }

        // Not found — trigger a full refresh then retry once
        await loadAllRepos()
        if let match = findIssue(for: key) {
            selectIssue(repoId: match.repoId, issue: match.issue)
        }
    }

    private func selectIssue(repoId: UUID, issue: FeedbackIssue) {
        // Navigate the sidebar to the correct repo; onChange(of: selection) → updateViewModel
        // will populate the issue list. Clear all filters so the issue is visible, then
        // set highlightedIssueNumber to mark it directly without touching searchQuery.
        selection = .allIssues(repoId: repoId)
        viewModel.clearFilters()
        viewModel.appFilter = []
        viewModel.highlightedIssueNumber = issue.number
    }

    /// Opens a feedback in the app (tapping a task's "Addresses feedback" chip): closes the
    /// detail/inspector sheets, then scrolls to and highlights the feedback in the list.
    private func openFeedback(_ number: Int) {
        taskFromFeedback = nil
        #if os(iOS)
        showInspector = false
        #endif
        guard let selection else { return }
        if let issue = viewModel.allIssues.first(where: { $0.number == number }) {
            selectIssue(repoId: selection.repoId, issue: issue)
        } else {
            viewModel.clearFilters()
            viewModel.appFilter = []
            viewModel.highlightedIssueNumber = number
        }
    }

    // MARK: - First-Load Backlog Snapshot

    /// Signature that changes whenever a loaded repo's issue count changes.
    /// Using "owner/repo:count" strings to make the trigger Equatable and content-sensitive.
    private var repoGroupSignature: [String] {
        allLoadedRepoGroups.map { "\($0.owner)/\($0.repo):\($0.issues.count)" }.sorted()
    }

    private func maybeSnapshotBacklog() {
        guard notificationSettings.hasRequestedAuthorization,
              notificationSettings.isEnabled,
              let service = notificationService else { return }

        let defaults = UserDefaults.standard

        // Migrate legacy single-Bool flag: if it was true, seed the new Set with all
        // currently-loaded repos so we don't flood them with old-backlog notifications.
        if defaults.bool(forKey: Self.legacyBacklogSnapshotKey) {
            var seeded = snapshottedRepos()
            for group in allLoadedRepoGroups {
                seeded.insert("\(group.owner)/\(group.repo)")
            }
            save(snapshottedRepos: seeded)
            defaults.removeObject(forKey: Self.legacyBacklogSnapshotKey)
        }

        var alreadySnapshotted = snapshottedRepos()
        let groups = allLoadedRepoGroups
        guard !groups.isEmpty else { return }

        for group in groups {
            let repoKey = "\(group.owner)/\(group.repo)"
            guard !alreadySnapshotted.contains(repoKey) else { continue }
            // Snapshot only this repo's issue keys.
            service.snapshotExistingIssues(loadedByRepo: [(group.owner, group.repo, group.issues)])
            alreadySnapshotted.insert(repoKey)
        }

        save(snapshottedRepos: alreadySnapshotted)
    }

    private func snapshottedRepos() -> Set<String> {
        let array = UserDefaults.standard.stringArray(forKey: Self.snapshottedReposKey) ?? []
        return Set(array)
    }

    private func save(snapshottedRepos: Set<String>) {
        UserDefaults.standard.set(Array(snapshottedRepos), forKey: Self.snapshottedReposKey)
    }
}
