import SwiftUI

struct TaskDetailView: View {
    let repo: RepoConfig
    let task: TaskItem
    var inspector: ProjectInspectorModel
    var versionStore: VersionStore

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var status: TaskStatus = .todo
    @State private var priority: TaskPriority = .med
    @State private var versionName: String?
    @State private var title = ""
    @State private var notes = ""
    @State private var seeded = false
    @State private var working = false
    @State private var errorMessage: String?
    private let service = TaskService()

    private var versions: [ProjectVersion] { versionStore.versions(owner: repo.owner, repo: repo.repo) }
    private var issueURL: URL? { URL(string: "https://github.com/\(repo.owner)/\(repo.repo)/issues/\(task.number)") }
    private var dirty: Bool {
        status != task.status || priority != task.priority || versionName != task.milestoneTitle
            || title != task.title || notes != FeedbackTaskRefParser.prose(of: task.body)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    DetailSection(title: "Status", systemImage: "circle.lefthalf.filled") { statusChips }
                    DetailSection(title: "Priority", systemImage: "flag") { priorityChips }
                    DetailSection(title: "Version", systemImage: "shippingbox") { versionMenu }
                    DetailSection(title: "Notes", systemImage: "text.alignleft") {
                        DetailTextEditor(placeholder: "Add details…", text: $notes)
                    }
                    if !task.feedbackRefs.isEmpty {
                        DetailSection(title: "Addresses feedback", systemImage: "link") { feedbackChips }
                    }
                    githubButton
                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote).foregroundStyle(.red)
                    }
                }
                .padding(20)
            }
            .scrollIndicators(.hidden)
            .background(LinearGradient(colors: [Color.primary.opacity(0.04), .clear], startPoint: .top, endPoint: .center).ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(working) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") { apply() }.fontWeight(.semibold).disabled(!dirty || working)
                }
            }
            .onAppear {
                guard !seeded else { return }
                status = task.status
                priority = task.priority
                versionName = task.milestoneTitle
                title = task.title
                notes = FeedbackTaskRefParser.prose(of: task.body)
                seeded = true
            }
        }
        #if os(macOS)
        .frame(width: 460, height: 620)
        #endif
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("#\(task.number)")
                    .font(.callout.monospaced().weight(.medium))
                    .foregroundStyle(.tertiary)
                HStack(spacing: 4) {
                    Circle().fill(status.accent).frame(width: 7, height: 7)
                    Text(status.displayName)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(status.accent)
                Spacer()
            }
            TextField("Task title", text: $title)
                .textFieldStyle(.plain)
                .font(.title2.weight(.semibold))
            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
        }
    }

    // MARK: Editors (all local — committed on Apply)

    private var statusChips: some View {
        HStack(spacing: 8) {
            ForEach(TaskStatus.allCases, id: \.self) { s in
                SelectChip(title: s.displayName, tint: s.accent, selected: status == s) { status = s }
            }
            Spacer(minLength: 0)
        }
    }

    private var priorityChips: some View {
        HStack(spacing: 8) {
            ForEach(TaskPriority.allCases, id: \.self) { p in
                SelectChip(title: p.displayName, tint: p.accent, selected: priority == p) { priority = p }
            }
            Spacer(minLength: 0)
        }
    }

    private var versionMenu: some View {
        Menu {
            Button("None") { versionName = nil }
            ForEach(versions) { v in Button(v.name) { versionName = v.name } }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "shippingbox").font(.system(size: 12)).foregroundStyle(.secondary)
                Text(versionName ?? "None")
                    .font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.045)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.06), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
    }

    private var feedbackChips: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 8)], alignment: .leading, spacing: 8) {
            ForEach(task.feedbackRefs, id: \.self) { n in
                Button {
                    if let url = URL(string: "https://github.com/\(repo.owner)/\(repo.repo)/issues/\(n)") { openURL(url) }
                } label: {
                    HStack(spacing: 4) {
                        Text("#\(n)").font(.caption.weight(.semibold).monospacedDigit())
                        Image(systemName: "arrow.up.forward").font(.system(size: 8, weight: .bold))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Capsule().fill(Color.primary.opacity(0.05)))
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.07), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var githubButton: some View {
        Button { if let issueURL { openURL(issueURL) } } label: {
            DetailCard {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.up.forward.app.fill").font(.system(size: 15)).foregroundStyle(.secondary)
                    Text("Open on GitHub").font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: Apply

    private func apply() {
        working = true; errorMessage = nil
        let milestoneNumber = versions.first { $0.name == versionName }?.milestoneNumber
        let newBody = FeedbackTaskRefParser.upsert(into: notes, refs: task.feedbackRefs)
        let previous = inspector.applyOptimistic(number: task.number, status: status, priority: priority,
                                                 title: title, body: newBody, milestone: .some(versionName))
        Task {
            do {
                try await service.applyEdits(repo: repo, task: task, title: title, prose: notes,
                                             status: status, priority: priority, milestoneNumber: milestoneNumber)
                dismiss()
            } catch {
                if let previous { inspector.restore(previous) }
                errorMessage = error.localizedDescription
                working = false
            }
        }
    }
}
