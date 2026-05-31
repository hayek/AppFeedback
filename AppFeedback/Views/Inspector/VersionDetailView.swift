import SwiftUI

struct VersionDetailView: View {
    let repo: RepoConfig
    @Bindable var version: ProjectVersion
    var inspector: ProjectInspectorModel
    var versionStore: VersionStore
    var onRelease: () -> Void                 // opens the recipients sheet (later unit)

    @State private var changelog: String = ""
    @State private var working = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section("What's new") {
                TextField("Changelog", text: $changelog, axis: .vertical).lineLimit(4...16)
                Button("Save changelog") { saveChangelog() }.disabled(working)
            }
            Section("Tasks in this version") {
                let tasks = inspector.tasks(forVersionNamed: version.name)
                if tasks.isEmpty { Text("No tasks assigned.").foregroundStyle(.secondary) }
                ForEach(tasks) { t in
                    HStack {
                        Image(systemName: t.isCompleted ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(t.isCompleted ? .green : .secondary)
                        Text("#\(t.number) \(t.title)").lineLimit(1)
                    }
                }
            }
            Section {
                if version.releasePublished {
                    let releasedLabel = releasedLabelText
                    Label(releasedLabel, systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                } else {
                    Button { onRelease() } label: { Label("Release…", systemImage: "paperplane.fill") }
                        .disabled(working)
                }
            }
            Section("Sent release emails") {
                let sent = versionStore.sentNotifications(owner: repo.owner, repo: repo.repo, versionName: version.name)
                if sent.isEmpty { Text("None sent yet.").foregroundStyle(.secondary) }
                ForEach(sent, id: \.id) { row in
                    SentNotificationRow(row: row)
                }
            }
            if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
        }
        #if os(macOS)
        .formStyle(.grouped)
        #endif
        .navigationTitle(version.name)
        .onAppear { changelog = version.changelog }
    }

}

private struct SentNotificationRow: View {
    let row: SentReleaseNotification

    var body: some View {
        HStack {
            iconView
            VStack(alignment: .leading) {
                Text(row.recipientEmail).font(.callout)
                Text(row.feedbackNumbers.map { "#\($0)" }.joined(separator: " "))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Text(row.sentAt.formatted(date: .omitted, time: .shortened))
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var iconView: some View {
        if row.status == .sent {
            Image(systemName: "envelope.fill").foregroundStyle(.secondary)
        } else {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        }
    }
}

extension VersionDetailView {
    private var releasedLabelText: String {
        if let date = version.releasedAt {
            return "Released · " + date.formatted(date: .abbreviated, time: .shortened)
        }
        return "Released"
    }

    private func saveChangelog() {
        working = true; errorMessage = nil
        let service = VersionService(store: versionStore)
        Task {
            do { try await service.updateChangelog(repo: repo, version: version, changelog: changelog) }
            catch { errorMessage = error.localizedDescription }
            working = false
        }
    }
}
