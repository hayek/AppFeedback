import SwiftUI

@MainActor
struct RootView: View {
    var store: RepoStore
    @State private var loaders: [UUID: IssueLoader] = [:]
    @State private var selection: SidebarSelection?
    @State private var viewModel = IssueListViewModel()
    @State private var showSettings = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(store: store, loaders: loaders, selection: $selection)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button { showSettings = true } label: {
                            Image(systemName: "gear")
                        }
                    }
                    #if os(iOS)
                    ToolbarItem(placement: .navigationBarLeading) {
                        if horizontalSizeClass == .compact {
                            Button {
                                withAnimation {
                                    columnVisibility = columnVisibility == .all ? .detailOnly : .all
                                }
                            } label: {
                                Image(systemName: "sidebar.left")
                            }
                        }
                    }
                    #endif
                }
        } detail: {
            if let selection {
                IssueListView(
                    viewModel: viewModel,
                    loader: loaders[selection.repoId],
                    allApps: allApps(for: selection.repoId),
                    onRefresh: {
                        guard let repo = store.repos.first(where: { $0.id == selection.repoId }),
                              let token = KeychainService.load(for: repo) else { return }
                        await loaders[selection.repoId]?.load(token: token)
                    }
                )
            } else {
                ContentUnavailableView(
                    "No repo selected",
                    systemImage: "tray",
                    description: Text("Add a repo in Settings, then select it from the sidebar.")
                )
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(store: store)
        }
        .onChange(of: selection) { _, newValue in
            guard let newValue else { return }
            updateViewModel(for: newValue)
        }
        .onChange(of: store.repos) { _, newRepos in
            syncLoaders(repos: newRepos)
        }
        .task {
            syncLoaders(repos: store.repos)
            loadAllRepos()
        }
    }

    private func allApps(for repoId: UUID) -> [String] {
        guard let loader = loaders[repoId],
              case .loaded(let issues, _) = loader.state else { return [] }
        return Array(Set(issues.compactMap(\.appName))).sorted()
    }

    private func updateViewModel(for selection: SidebarSelection) {
        guard let loader = loaders[selection.repoId],
              case .loaded(let issues, _) = loader.state else { return }
        viewModel.allIssues = issues
        viewModel.clearFilters()
        switch selection {
        case .allIssues:          viewModel.appFilter = nil
        case .app(_, let name):   viewModel.appFilter = name
        }
    }

    private func syncLoaders(repos: [RepoConfig]) {
        for repo in repos where loaders[repo.id] == nil {
            loaders[repo.id] = IssueLoader(config: repo)
        }
        let ids = Set(repos.map(\.id))
        loaders = loaders.filter { ids.contains($0.key) }
    }

    private func loadAllRepos() {
        for repo in store.repos {
            guard let loader = loaders[repo.id],
                  let token = KeychainService.load(for: repo) else { continue }
            Task { await loader.load(token: token) }
        }
    }
}
