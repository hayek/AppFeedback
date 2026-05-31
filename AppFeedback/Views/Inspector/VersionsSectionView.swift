import SwiftUI

struct VersionsSectionView: View {
    let repo: RepoConfig
    var inspector: ProjectInspectorModel
    var versionStore: VersionStore
    var onCreateVersion: () -> Void
    var onOpenVersion: (ProjectVersion) -> Void

    var body: some View {
        Button { onCreateVersion() } label: { Label("New Version", systemImage: "plus") }
        ForEach(versionStore.versions(owner: repo.owner, repo: repo.repo)) { version in
            Button { onOpenVersion(version) } label: {
                VersionRow(version: version,
                           state: version.derivedState(anyTaskStarted: inspector.anyTaskStarted(versionNamed: version.name)),
                           taskCount: inspector.tasks(forVersionNamed: version.name).count)
            }
            .buttonStyle(.plain)
        }
    }
}

private struct VersionRow: View {
    let version: ProjectVersion
    let state: VersionState
    let taskCount: Int

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(version.name).font(.callout.weight(.medium))
                Text("\(taskCount) task\(taskCount == 1 ? "" : "s")").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Text(badge).font(.caption2.weight(.semibold))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(badgeColor.opacity(0.18), in: Capsule())
                .foregroundStyle(badgeColor)
        }
    }
    private var badge: String {
        switch state {
        case .new: return "NEW"
        case .wip: return "WIP"
        case .released: return "RELEASED"
        }
    }
    private var badgeColor: Color {
        switch state {
        case .new: return .secondary
        case .wip: return .orange
        case .released: return .green
        }
    }
}
