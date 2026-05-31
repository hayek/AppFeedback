import SwiftUI

struct ProjectInspectorPanel: View {
    let repo: RepoConfig?
    var inspector: ProjectInspectorModel
    var versionStore: VersionStore
    var onCreateTask: () -> Void
    var onOpenTask: (TaskItem) -> Void
    var onCreateVersion: () -> Void
    var onOpenVersion: (ProjectVersion) -> Void

    var body: some View {
        Group {
            if let repo {
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        section(title: "Tasks", count: inspector.filteredTasks.count) {
                            TasksSectionView(repo: repo, inspector: inspector, onCreateTask: onCreateTask, onOpenTask: onOpenTask)
                        }
                        section(title: "Versions",
                                count: versionStore.versions(owner: repo.owner, repo: repo.repo).count) {
                            VersionsSectionView(
                                repo: repo, inspector: inspector, versionStore: versionStore,
                                onCreateVersion: onCreateVersion, onOpenVersion: onOpenVersion)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 28)
                }
                .scrollIndicators(.hidden)
                .background(atmosphere)
            } else {
                ContentUnavailableView {
                    Label("No project selected", systemImage: "sidebar.right")
                } description: {
                    Text("Pick a project in the sidebar to see its tasks and versions.")
                }
                .background(atmosphere)
            }
        }
        .navigationTitle("Tasks & Versions")
    }

    @ViewBuilder
    private func section<Content: View>(title: String, count: Int,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            PanelSectionHeader(title: title, count: count)
            content()
        }
    }

    /// A whisper-soft top gradient gives the panel depth without competing with the cards.
    private var atmosphere: some View {
        LinearGradient(
            colors: [Color.primary.opacity(0.04), Color.clear],
            startPoint: .top, endPoint: .center
        )
        .ignoresSafeArea()
    }
}
