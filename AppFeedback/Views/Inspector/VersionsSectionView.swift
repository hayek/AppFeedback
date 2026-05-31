import SwiftUI

struct VersionsSectionView: View {
    let repo: RepoConfig
    var inspector: ProjectInspectorModel
    var versionStore: VersionStore
    var onCreateVersion: () -> Void
    var onOpenVersion: (ProjectVersion) -> Void

    var body: some View {
        Text("Versions").foregroundStyle(.secondary)   // stub — replaced in U15
    }
}
