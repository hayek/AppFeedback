import SwiftUI

struct RepoSectionView: View {
    let repo: RepoConfig
    let issues: [FeedbackIssue]
    let allApps: [String]
    @Binding var selection: SidebarSelection?
    @State private var isExpanded = true

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            AppRowView(
                label: "All Issues",
                count: issues.count,
                color: .secondary,
                isSelected: selection == .allIssues(repoId: repo.id)
            )
            .onTapGesture { selection = .allIssues(repoId: repo.id) }
            .padding(.leading, 8)

            ForEach(allApps, id: \.self) { app in
                let count = issues.filter { $0.appName == app }.count
                let color = ColorPalette.color(for: app, in: allApps)
                AppRowView(
                    label: app,
                    count: count,
                    color: color,
                    isSelected: selection == .app(repoId: repo.id, appName: app)
                )
                .onTapGesture { selection = .app(repoId: repo.id, appName: app) }
                .padding(.leading, 8)
            }
        } label: {
            Text(repo.displayName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.5)
        }
    }
}
