import SwiftUI
import SwiftData

@MainActor
struct RootView: View {
    var store: RepoStore
    var seenStore: SeenIssueStore
    var cacheContext: ModelContext
    @State private var loaders: [UUID: IssueLoader] = [:]
    @State private var selection: SidebarSelection?
    @State private var viewModel = IssueListViewModel()
    @State private var summaryVM: UnreadSummaryViewModel?
    @State private var showSettings = false
    @State private var showAddRepo = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @Environment(ActivityLog.self) private var activityLog
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
        NavigationSplitView(columnVisibility: $columnVisibility) {
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
                                await loaders[selection.repoId]?.load(token: token)
                            }
                            await mailPoll
                        },
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
    }

    #if os(iOS)
    private func navigationTitle(for selection: SidebarSelection) -> String {
        switch selection {
        case .allIssues:
            return "All Apps"
        case .app(_, let appName):
            return appName
        }
    }
    #endif

    private func allApps(for repoId: UUID) -> [String] {
        guard let loader = loaders[repoId],
              case .loaded(let issues, _) = loader.state else { return [] }
        return Array(Set(issues.compactMap(\.appName))).sorted()
    }

    private func updateViewModel(for selection: SidebarSelection) {
        guard let loader = loaders[selection.repoId],
              case .loaded(let issues, _) = loader.state else { return }
        let owner = store.repos.first(where: { $0.id == selection.repoId })?.owner ?? ""
        let repoName = store.repos.first(where: { $0.id == selection.repoId })?.repo  ?? ""
        viewModel.hiddenApps = store.hiddenAppsFor(selection.repoId)
        viewModel.attachSeenStore(seenStore, owner: owner, repo: repoName)
        viewModel.applyLoaded(issues)
        viewModel.clearFilters()
        switch selection {
        case .allIssues:
            viewModel.appFilter = []
            viewModel.allowsAppFilter = true
        case .app(_, let name):
            viewModel.appFilter = [name]
            viewModel.allowsAppFilter = false
        }
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

    private func loadAllRepos() async {
        await loadRepos(store.repos)
    }

    private func loadRepos(_ repos: [RepoConfig]) async {
        await withTaskGroup(of: Void.self) { group in
            for repo in repos {
                guard let loader = loaders[repo.id] else { continue }
                group.addTask {
                    guard let token = await KeychainService.load(for: repo) else { return }
                    await loader.load(token: token)
                }
            }
        }
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
