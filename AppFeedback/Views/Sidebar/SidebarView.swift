import SwiftUI

struct SidebarView: View {
    @Bindable var store: ProductStore
    let loaders: [UUID: IssueLoader]
    var seenStore: SeenIssueStore
    @Binding var selection: SidebarSelection?
    var onAddRepo: () -> Void = {}
    var onOpenProductSettings: (UUID) -> Void = { _ in }

    var body: some View {
        Group {
            if store.repos.isEmpty {
                ContentUnavailableView {
                    Label("No Products", systemImage: "tray")
                } description: {
                    Text("Add a product to start collecting feedback.")
                } actions: {
                    Button("+ Add Product") { onAddRepo() }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                List(selection: $selection) {
                    ForEach(store.repos) { repo in
                        let issues = issuesFor(repo)
                        let apps = allAppsFor(issues)
                        RepoSectionView(
                            repo: repo,
                            issues: issues,
                            allApps: apps,
                            selection: $selection,
                            store: store,
                            seenStore: seenStore,
                            onOpenSettings: onOpenProductSettings
                        )
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .navigationTitle("Feedback")
        #if os(macOS)
        .frame(minWidth: 200)
        #endif
    }

    private func issuesFor(_ repo: ProductConfig) -> [FeedbackIssue] {
        guard let loader = loaders[repo.id],
              case .loaded(let issues, _) = loader.state else { return [] }
        return issues
    }

    private func allAppsFor(_ issues: [FeedbackIssue]) -> [String] {
        Array(Set(issues.compactMap(\.appName))).sorted()
    }
}
