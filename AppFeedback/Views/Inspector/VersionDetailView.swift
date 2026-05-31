import SwiftUI

struct VersionDetailView: View {
    let repo: RepoConfig
    @Bindable var version: ProjectVersion
    var inspector: ProjectInspectorModel
    var versionStore: VersionStore
    var onRelease: () -> Void
    let canEmail: Bool

    @Environment(\.dismiss) private var dismiss
    @State private var changelog: String = ""
    @State private var working = false
    @State private var errorMessage: String?
    @State private var taskToOpen: TaskItem?

    private var tasks: [TaskItem] { inspector.tasks(forVersionNamed: version.name) }
    private var doneCount: Int { tasks.filter(\.isCompleted).count }
    private var state: VersionState { version.derivedState(anyTaskStarted: inspector.anyTaskStarted(versionNamed: version.name)) }
    private var sent: [SentReleaseNotification] {
        versionStore.sentNotifications(owner: repo.owner, repo: repo.repo, versionName: version.name)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                changelogSection
                tasksSection
                releaseSection
                sentSection
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote).foregroundStyle(.red)
                }
            }
            .padding(20)
        }
        .scrollIndicators(.hidden)
        .background(LinearGradient(colors: [Color.primary.opacity(0.04), .clear], startPoint: .top, endPoint: .center).ignoresSafeArea())
        .navigationTitle(version.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        .onAppear { changelog = version.changelog }
        .sheet(item: $taskToOpen) { task in
            TaskDetailView(repo: repo, task: task, inspector: inspector, versionStore: versionStore)
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(version.name)
                    .font(.largeTitle.weight(.bold))
                VersionStatePill(state: state)
                Spacer(minLength: 0)
            }
            if !tasks.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("\(doneCount) of \(tasks.count) done")
                            .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        Spacer()
                    }
                    ThinProgressBar(fraction: tasks.isEmpty ? 0 : Double(doneCount) / Double(tasks.count),
                                    tint: state.accent)
                }
            }
        }
    }

    // MARK: Changelog

    private var changelogSection: some View {
        DetailSection(title: "What's new", systemImage: "sparkles") {
            DetailCard {
                VStack(alignment: .leading, spacing: 12) {
                    DetailTextEditor(placeholder: "What changed in this version…", text: $changelog)
                    HStack {
                        Spacer()
                        SubtleButton(title: "Save", systemImage: "checkmark", enabled: changelog != version.changelog && !working) {
                            saveChangelog()
                        }
                    }
                }
            }
        }
    }

    // MARK: Tasks

    private var tasksSection: some View {
        DetailSection(title: "Tasks in this version", systemImage: "checklist") {
            DetailCard(padding: 6) {
                if tasks.isEmpty {
                    PanelEmptyState(icon: "tray", message: "No tasks assigned yet.")
                        .padding(8)
                } else {
                    VStack(spacing: 2) {
                        ForEach(tasks) { task in
                            CompactTaskRow(task: task) { taskToOpen = task }
                        }
                    }
                }
            }
        }
    }

    // MARK: Release

    @ViewBuilder private var releaseSection: some View {
        if version.releasePublished {
            DetailCard {
                HStack(spacing: 12) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.title2).foregroundStyle(VersionState.released.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Released").font(.subheadline.weight(.semibold))
                        Text(releasedSubtitle).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
        } else if canEmail {
            PrimaryActionButton(title: "Release…", systemImage: "paperplane.fill") { onRelease() }
                .disabled(working)
        } else {
            DetailCard {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Add a mail account in Settings to email users on release.", systemImage: "envelope.badge")
                        .font(.footnote).foregroundStyle(.secondary)
                    SubtleButton(title: "Mark released (no email)", systemImage: "checkmark.seal", enabled: !working) {
                        markReleasedNoEmail()
                    }
                }
            }
        }
    }

    // MARK: Sent emails

    private var sentSection: some View {
        DetailSection(title: "Sent release emails", systemImage: "envelope") {
            DetailCard(padding: sent.isEmpty ? 14 : 6) {
                if sent.isEmpty {
                    PanelEmptyState(icon: "envelope", message: "None sent yet.")
                } else {
                    VStack(spacing: 2) {
                        ForEach(sent, id: \.id) { SentNotificationRow(row: $0) }
                    }
                }
            }
        }
    }

    private var releasedSubtitle: String {
        var parts: [String] = []
        if let date = version.releasedAt { parts.append(date.formatted(date: .abbreviated, time: .shortened)) }
        if let tag = version.releaseTag { parts.append(tag) }
        return parts.isEmpty ? "Milestone closed" : parts.joined(separator: " · ")
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

    private func markReleasedNoEmail() {
        working = true; errorMessage = nil
        let service = VersionService(store: versionStore)
        let tag = version.releaseTag ?? "v\(version.name)"
        Task {
            do { _ = try await service.release(repo: repo, version: version, tag: tag, target: nil, publishRelease: false, now: Date()) }
            catch { errorMessage = error.localizedDescription }
            working = false
        }
    }
}

private struct SentNotificationRow: View {
    let row: SentReleaseNotification

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: row.status == .sent ? "envelope.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(row.status == .sent ? Color.secondary : Color.red)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.recipientEmail).font(.callout)
                if !row.feedbackNumbers.isEmpty {
                    Text(row.feedbackNumbers.map { "#\($0)" }.joined(separator: " "))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 6)
            Text(row.sentAt.formatted(date: .omitted, time: .shortened))
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 8).padding(.horizontal, 8)
    }
}
