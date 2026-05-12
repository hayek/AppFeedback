#if os(macOS)
import SwiftUI
import AppKit

struct MailDefaultsSection: View {
    @Environment(MailSettingsStore.self) private var settingsStore

    @State private var headerText: String = ""
    @State private var footerText: String = ""
    @State private var pollIntervalMinutes: Int = 5
    @State private var attachmentFolderDisplayPath: String = "Default (~/Downloads)"
    @State private var didLoad = false
    @State private var saveTask: Task<Void, Never>?
    @State private var copiedToken: String?

    var body: some View {
        Group {
            Section("Header") {
                TextEditor(text: $headerText).font(.body).frame(minHeight: 120)
            }
            Section("Footer") {
                TextEditor(text: $footerText).font(.body).frame(minHeight: 120)
            }
            Section("Attachments") {
                HStack {
                    Button("Attachments folder…") { pickAttachmentFolder() }
                    Text(attachmentFolderDisplayPath)
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            Section("Fetching") {
                Stepper(
                    "Every \(pollIntervalMinutes) minute\(pollIntervalMinutes == 1 ? "" : "s")",
                    value: $pollIntervalMinutes,
                    in: 1...60
                )
                .onChange(of: pollIntervalMinutes) { _, _ in scheduleSave() }
            }
            Section("Placeholders") {
                placeholdersHint
            }
        }
        .task { load() }
        .onChange(of: headerText) { _, _ in scheduleSave() }
        .onChange(of: footerText) { _, _ in scheduleSave() }
    }

    private func load() {
        headerText = MailTemplatePlainText.from(html: settingsStore.settings.templateHeaderHTML)
        footerText = MailTemplatePlainText.from(html: settingsStore.settings.templateFooterHTML)
        pollIntervalMinutes = max(1, min(60, settingsStore.settings.pollIntervalSeconds / 60))
        resolveDisplayPath()
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
                attachmentFolderDisplayPath = url.path
            }
        }
    }

    private func resolveDisplayPath() {
        guard let data = settingsStore.settings.attachmentFolderBookmark else {
            attachmentFolderDisplayPath = "Default (~/Downloads)"
            return
        }
        var stale = false
        if let url = try? URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) {
            attachmentFolderDisplayPath = url.path
        } else {
            attachmentFolderDisplayPath = "Default (~/Downloads)"
        }
    }

    private var placeholdersHint: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Drop these tokens into the header or footer — they'll be replaced when the email is sent. Click a token to copy it.")
                .font(.caption).foregroundStyle(.secondary)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 2) {
                ForEach(Self.placeholderHints, id: \.token) { hint in
                    GridRow {
                        Button { copyToken(hint.token) } label: {
                            HStack(spacing: 4) {
                                Text(hint.token).font(.system(.caption, design: .monospaced))
                                Image(systemName: copiedToken == hint.token ? "checkmark" : "doc.on.doc")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        Text(hint.descriptionText).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
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

    private struct PlaceholderHint { let token: String; let descriptionText: String }
    private static let placeholderHints: [PlaceholderHint] = [
        .init(token: "{{sender_name}}",     descriptionText: "Your sender display name"),
        .init(token: "{{sender_email}}",    descriptionText: "Your from address"),
        .init(token: "{{recipient_email}}", descriptionText: "The recipient's email"),
        .init(token: "{{app_name}}",        descriptionText: "App the issue belongs to"),
        .init(token: "{{issue_title}}",     descriptionText: "Title of the issue"),
        .init(token: "{{issue_url}}",       descriptionText: "Link to the issue"),
        .init(token: "{{date}}",            descriptionText: "Current date and time")
    ]
}
#endif
