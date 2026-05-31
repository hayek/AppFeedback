import SwiftUI

struct VersionsSectionView: View {
    let repo: RepoConfig
    var inspector: ProjectInspectorModel
    var versionStore: VersionStore
    var onCreateVersion: () -> Void
    var onOpenVersion: (ProjectVersion) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PanelAddButton(title: "New Version", action: onCreateVersion)

            let versions = versionStore.versions(owner: repo.owner, repo: repo.repo)
            if versions.isEmpty {
                PanelEmptyState(icon: "shippingbox", message: "No versions yet.")
            } else {
                ForEach(versions) { version in
                    VersionCard(
                        name: version.name,
                        state: version.derivedState(anyTaskStarted: inspector.anyTaskStarted(versionNamed: version.name)),
                        taskCount: inspector.tasks(forVersionNamed: version.name).count,
                        action: { onOpenVersion(version) }
                    )
                }
            }
        }
    }
}
