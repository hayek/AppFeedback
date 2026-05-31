import SwiftUI

struct ProjectInspectorPanel: View {
    let repo: RepoConfig?
    var inspector: ProjectInspectorModel
    var versionStore: VersionStore
    var onCreateTask: () -> Void
    var onCreateVersion: () -> Void
    var onOpenVersion: (ProjectVersion) -> Void

    var body: some View {
        Group {
            if let repo {
                List {
                    Section("Tasks") {
                        TasksSectionView(repo: repo, inspector: inspector, onCreateTask: onCreateTask)
                    }
                    Section("Versions") {
                        VersionsSectionView(
                            repo: repo, inspector: inspector, versionStore: versionStore,
                            onCreateVersion: onCreateVersion, onOpenVersion: onOpenVersion)
                    }
                }
                #if os(macOS)
                .listStyle(.inset)
                #else
                .listStyle(.insetGrouped)
                #endif
            } else {
                ContentUnavailableView("No project selected", systemImage: "sidebar.right")
            }
        }
        .navigationTitle("Tasks & Versions")
    }
}
