import SwiftUI

struct SidebarView: View {
    @Bindable var store: RepoStore
    let loaders: [UUID: IssueLoader]
    @Binding var selection: SidebarSelection?

    var body: some View {
        List {
            ForEach(store.repos) { repo in
                let issues = issuesFor(repo)
                let apps = allAppsFor(issues)
                RepoSectionView(
                    repo: repo,
                    issues: issues,
                    allApps: apps,
                    selection: $selection
                )
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Feedback")
        #if os(macOS)
        .frame(minWidth: 200)
        #endif
    }

    private func issuesFor(_ repo: RepoConfig) -> [FeedbackIssue] {
        guard let loader = loaders[repo.id],
              case .loaded(let issues, _) = loader.state else { return [] }
        return issues
    }

    private func allAppsFor(_ issues: [FeedbackIssue]) -> [String] {
        Array(Set(issues.compactMap(\.appName))).sorted()
    }
}
