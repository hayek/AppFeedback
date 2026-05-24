#if os(macOS)
import SwiftUI
import AppKit

/// Shared template + sync defaults section group. Body returns a `Group` of Sections so it can
/// be composed inside the outer `Form` in `EmailSettingsView` (single scrolling surface).
struct MailDefaultsSection: View {
    @Environment(MailSettingsStore.self) private var settingsStore

    @State private var headerText: String = ""
    @State private var footerText: String = ""
    @State private var defaultSubject: String = ""
    @State private var pollIntervalMinutes: Int = 5
    @State private var attachmentFolderURL: URL? = nil
    @State private var didLoad = false
    @State private var saveTask: Task<Void, Never>?

    var body: some View {
        Group {
            templatesSection
            attachmentsSection
            fetchingSection
        }
        .task { load() }
        .onChange(of: headerText) { _, _ in scheduleSave() }
        .onChange(of: footerText) { _, _ in scheduleSave() }
        .onChange(of: defaultSubject) { _, _ in scheduleSave() }
    }

    // MARK: - Templates

    private var templatesSection: some View {
        Section {
            defaultSubjectField
            templateEditor(label: "Header", icon: "text.alignleft", text: $headerText)
            templateEditor(label: "Footer", icon: "text.append", text: $footerText)
        } header: {
            Text("Templates")
        } footer: {
            Text("Default Subject seeds the subject line on new messages. Header and footer wrap every outgoing reply. Placeholders below work in all three.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var defaultSubjectField: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "textformat")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("Default Subject")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.4)
                Spacer()
            }
            TextField("", text: $defaultSubject, prompt: Text("Feedback on {{app_name}}"))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func templateEditor(label: String, icon: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.4)
                Spacer()
                Text("\(text.wrappedValue.count) chars")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            TextEditor(text: text)
                .font(.system(size: 12))
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: 96)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.gray.opacity(0.25), lineWidth: 0.5)
                )
        }
        .padding(.vertical, 4)
    }

    // MARK: - Attachments

    private var attachmentsSection: some View {
        Section("Download Attachments Path") {
            HStack(spacing: 12) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.tint)
                    .symbolRenderingMode(.hierarchical)
                    .frame(width: 22)
                Text(attachmentFolderURL?.path ?? "~/Downloads")
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Button("Change…") { pickAttachmentFolder() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                if attachmentFolderURL != nil {
                    Button {
                        settingsStore.update { $0.attachmentFolderBookmark = nil }
                        attachmentFolderURL = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Reset to default")
                }
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: - Fetching

    private var fetchingSection: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: "arrow.clockwise.circle.fill")
                    .font(.system(size: 16))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.tint)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Check for new mail")
                        .font(.system(size: 13, weight: .medium))
                    Text("Applies to every auto-fetching account.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker("", selection: $pollIntervalMinutes) {
                    ForEach(Self.pollIntervalChoices, id: \.self) { mins in
                        Text(intervalLabel(mins)).tag(mins)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .onChange(of: pollIntervalMinutes) { _, _ in scheduleSave() }
            }
            .padding(.vertical, 2)
        } header: {
            Text("Sync")
        }
    }

    private static let pollIntervalChoices: [Int] = [1, 2, 5, 10, 15, 30, 60]

    private func intervalLabel(_ minutes: Int) -> String {
        switch minutes {
        case 1:  return "Every minute"
        case 60: return "Every hour"
        default: return "Every \(minutes) minutes"
        }
    }

    // MARK: - Persistence

    private func load() {
        headerText = MailTemplatePlainText.from(html: settingsStore.settings.templateHeaderHTML)
        footerText = MailTemplatePlainText.from(html: settingsStore.settings.templateFooterHTML)
        defaultSubject = settingsStore.settings.defaultSubjectTemplate
        pollIntervalMinutes = max(1, min(60, settingsStore.settings.pollIntervalSeconds / 60))
        resolveDisplayURL()
        didLoad = true
    }

    private func scheduleSave() {
        guard didLoad else { return }
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if Task.isCancelled { return }
            settingsStore.update { s in
                s.templateHeaderHTML = MailTemplatePlainText.toHTML(headerText)
                s.templateFooterHTML = MailTemplatePlainText.toHTML(footerText)
                s.defaultSubjectTemplate = defaultSubject
                s.pollIntervalSeconds = pollIntervalMinutes * 60
            }
        }
    }

    private func pickAttachmentFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Pick a folder to save downloaded attachments"
        if panel.runModal() == .OK, let url = panel.url {
            if let bookmark = try? url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ) {
                settingsStore.update { $0.attachmentFolderBookmark = bookmark }
                attachmentFolderURL = url
            }
        }
    }

    private func resolveDisplayURL() {
        guard let data = settingsStore.settings.attachmentFolderBookmark else {
            attachmentFolderURL = nil
            return
        }
        var stale = false
        if let url = try? URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) {
            attachmentFolderURL = url
        } else {
            attachmentFolderURL = nil
        }
    }

}

/// Always-visible placeholders reference. Rendered OUTSIDE the Form so it sits on the
/// window background without a grouped-section card.
struct MailPlaceholdersList: View {
    @State private var copiedToken: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "curlybraces")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("Available placeholders")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.4)
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Self.placeholderHints, id: \.token) { hint in
                    row(hint)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func row(_ hint: PlaceholderHint) -> some View {
        HStack(spacing: 10) {
            Button {
                copyToken(hint.token)
            } label: {
                HStack(spacing: 4) {
                    Text(hint.token)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.primary)
                    Image(systemName: copiedToken == hint.token ? "checkmark.circle.fill" : "doc.on.doc")
                        .font(.system(size: 10))
                        .foregroundStyle(copiedToken == hint.token ? Color.green : Color.gray.opacity(0.6))
                }
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.secondary.opacity(0.10))
                )
                .contentShape(Rectangle())
                .animation(.easeInOut(duration: 0.15), value: copiedToken)
            }
            .buttonStyle(.plain)
            .help("Copy \(hint.token)")
            Text(hint.descriptionText)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.vertical, 1)
    }

    private func copyToken(_ token: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(token, forType: .string)
        copiedToken = token
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            if copiedToken == token { copiedToken = nil }
        }
    }

    fileprivate struct PlaceholderHint { let token: String; let descriptionText: String }
    fileprivate static let placeholderHints: [PlaceholderHint] = [
        .init(token: "{{sender_name}}",     descriptionText: "Your sender display name"),
        .init(token: "{{sender_email}}",    descriptionText: "Your from address"),
        .init(token: "{{recipient_email}}", descriptionText: "The recipient's email"),
        .init(token: "{{app_name}}",        descriptionText: "App the issue belongs to"),
        .init(token: "{{issue_title}}",     descriptionText: "Title of the issue"),
        .init(token: "{{issue_url}}",       descriptionText: "Link to the issue"),
        .init(token: "{{feedback_body}}",   descriptionText: "Original feedback description"),
        .init(token: "{{feedback_attachments}}", descriptionText: "Feedback attachments (images and files)"),
        .init(token: "{{date}}",            descriptionText: "Current date and time")
    ]
}
#endif
