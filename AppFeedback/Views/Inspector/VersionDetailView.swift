import SwiftUI

struct VersionDetailView: View {
    let repo: ProductConfig
    @Bindable var version: ProjectVersion
    var inspector: ProjectInspectorModel
    var versionStore: VersionStore
    var onRelease: () -> Void
    /// Renames the version: PATCHes the GitHub milestone, then cascades the local copies of the old
    /// name. Supplied by `RootView`, which owns the cache context and the filter store.
    var onRename: (String) async throws -> Void
    var onDeleteTask: (TaskItem) -> Void
    var onOpenFeedback: (Int) -> Void
    let canEmail: Bool

    @Environment(\.dismiss) private var dismiss
    @State private var title: String = ""          // release title
    @State private var changelog: String = ""
    @State private var name: String = ""           // version number — the identity key
    @State private var working = false
    @State private var errorMessage: String?
    @State private var taskToOpen: TaskItem?
    @State private var showDeleteConfirm = false

    private var tasks: [TaskItem] { inspector.tasks(forVersionNamed: version.name) }
    private var doneCount: Int { tasks.filter(\.isCompleted).count }
    private var state: VersionState { version.derivedState(anyTaskStarted: inspector.anyTaskStarted(versionNamed: version.name)) }
    private var sent: [SentReleaseNotification] { versionStore.sentNotifications(for: version) }

    /// A published version cannot be renamed: its git tag and release emails are already public.
    private var canRename: Bool { !version.releasePublished }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var nameChanged: Bool { canRename && trimmedName != version.name }
    private var dirty: Bool {
        title != version.releaseTitle || changelog != version.changelog || nameChanged
    }
    /// Apply is blocked on an empty name — but only when the name is what's being edited, so a
    /// published version (whose name field is read-only) can still have its changelog applied.
    private var canApply: Bool { dirty && !(canRename && trimmedName.isEmpty) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                // Rendered right below the header — right where the name field the user is fixing
                // sits — so a rename failure is never scrolled out of view by tasks/emails below.
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote).foregroundStyle(.red)
                }
                titleSection
                changelogSection
                tasksSection
                releaseSection
                sentSection
                deleteButton
            }
            .padding(20)
        }
        .scrollIndicators(.hidden)
        .background(LinearGradient(colors: [Color.primary.opacity(0.04), .clear], startPoint: .top, endPoint: .center).ignoresSafeArea())
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            // .primaryAction (not .confirmationAction) so Return is NOT bound to Apply —
            // otherwise pressing Return in the multi-line "What's new" editor would dismiss
            // the sheet instead of inserting a newline. Apply is click-only.
            ToolbarItem(placement: .primaryAction) {
                Button("Apply") { applyDetails() }
                    .buttonStyle(.borderedProminent)
                    .fontWeight(.semibold)
                    .disabled(!canApply || working)
            }
        }
        .confirmationDialog("Delete version \(version.name)?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete Version", role: .destructive) { deleteVersion() }
        } message: {
            Text("This removes the milestone on GitHub and the version here. Tasks are not deleted.")
        }
        .onAppear { changelog = version.changelog; title = version.releaseTitle; name = version.name }
        .sheet(item: $taskToOpen) { task in
            TaskDetailView(repo: repo, task: task, inspector: inspector, versionStore: versionStore,
                           onDelete: { taskToOpen = nil; onDeleteTask(task) },
                           onOpenFeedback: onOpenFeedback)
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if canRename {
                    TextField("1.2.0", text: $name)
                        .textFieldStyle(.plain)
                        .font(.largeTitle.weight(.bold))
                        .disabled(working)
                } else {
                    Text(version.name).font(.largeTitle.weight(.bold))
                }
                Spacer(minLength: 8)
                // The rename holds the sheet open while GitHub is PATCHed, so show it's working.
                if working { ProgressView().controlSize(.small) }
                VersionStatePill(state: state)
            }
            if !tasks.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("\(doneCount) of \(tasks.count) done")
                            .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        Spacer()
                    }
                    ThinProgressBar(fraction: Double(doneCount) / Double(tasks.count), tint: state.accent)
                }
            }
        }
    }

    private var titleSection: some View {
        DetailSection(title: "Release title", systemImage: "tag") {
            TextField("e.g. Performance & polish", text: $title)
                .textFieldStyle(.plain)
                .font(.body)
                .padding(11)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.045)))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.06), lineWidth: 1))
        }
    }

    private var changelogSection: some View {
        DetailSection(title: "What's new", systemImage: "sparkles") {
            DetailCard {
                DetailTextEditor(placeholder: "What changed in this version…", text: $changelog)
            }
        }
    }

    private var tasksSection: some View {
        DetailSection(title: "Tasks in this version", systemImage: "checklist") {
            DetailCard(padding: 6) {
                if tasks.isEmpty {
                    PanelEmptyState(icon: "tray", message: "No tasks assigned yet.").padding(8)
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

    @ViewBuilder private var releaseSection: some View {
        if version.releasePublished {
            DetailCard {
                HStack(spacing: 12) {
                    Image(systemName: "checkmark.seal.fill").font(.title2).foregroundStyle(VersionState.released.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Released").font(.subheadline.weight(.semibold))
                        Text(releasedSubtitle).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
        } else if canEmail {
            PrimaryActionButton(title: "Release…", systemImage: "paperplane.fill") { releaseFlow() }
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

    private var deleteButton: some View {
        Button(role: .destructive) { showDeleteConfirm = true } label: {
            HStack(spacing: 10) {
                Image(systemName: "trash").font(.system(size: 14))
                Text("Delete Version").font(.subheadline.weight(.medium))
                Spacer()
            }
            .foregroundStyle(.red)
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.red.opacity(0.10)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.red.opacity(0.20), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var releasedSubtitle: String {
        var parts: [String] = []
        if let date = version.releasedAt { parts.append(date.formatted(date: .abbreviated, time: .shortened)) }
        if let tag = version.releaseTag { parts.append(tag) }
        return parts.isEmpty ? "Milestone closed" : parts.joined(separator: " · ")
    }

    // MARK: Actions

    /// Title/changelog keep their fire-and-forget behaviour (dismiss, write in the background). A
    /// rename does not: it holds the sheet open and surfaces failures, because a rename that
    /// silently failed looks exactly like one that succeeded.
    private func applyDetails() {
        let service = VersionService(store: versionStore)
        let newTitle = title, newChangelog = changelog, newName = trimmedName
        let mustRename = nameChanged
        let detailsChanged = newTitle != version.releaseTitle || newChangelog != version.changelog

        guard mustRename else {
            dismiss()
            Task { try? await service.updateDetails(repo: repo, version: version, title: newTitle, changelog: newChangelog) }
            return
        }

        working = true; errorMessage = nil
        Task {
            do {
                if detailsChanged {
                    try await service.updateDetails(repo: repo, version: version, title: newTitle, changelog: newChangelog)
                }
                try await onRename(newName)
                working = false
                dismiss()
            } catch {
                // Keep the sheet up: the name field still holds what the user typed, so they can fix
                // a duplicate and retry rather than lose the edit to a silent failure.
                errorMessage = error.localizedDescription
                working = false
            }
        }
    }

    /// Persist the edited title/changelog — and any pending rename — before opening the release
    /// flow, so the tag and the release emails carry the new name. A version can only be released
    /// while unpublished, i.e. exactly when a rename is still possible.
    private func releaseFlow() {
        let service = VersionService(store: versionStore)
        let newTitle = title, newChangelog = changelog, newName = trimmedName
        let mustRename = nameChanged
        working = true; errorMessage = nil
        Task {
            do {
                if newTitle != version.releaseTitle || newChangelog != version.changelog {
                    try await service.updateDetails(repo: repo, version: version, title: newTitle, changelog: newChangelog)
                }
                if mustRename { try await onRename(newName) }
                working = false
                onRelease()
            } catch {
                errorMessage = error.localizedDescription
                working = false
            }
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

    private func deleteVersion() {
        let service = VersionService(store: versionStore)
        dismiss()
        Task { try? await service.deleteVersion(repo: repo, version: version) }
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
