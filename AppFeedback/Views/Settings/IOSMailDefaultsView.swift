#if os(iOS)
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct IOSMailDefaultsView: View {
    @Environment(MailSettingsStore.self) private var settingsStore

    @State private var headerText: String = ""
    @State private var footerText: String = ""
    @State private var pollIntervalMinutes: Int = 5
    @State private var attachmentFolderDisplayPath: String = "Default"
    @State private var didLoad = false
    @State private var saveTask: Task<Void, Never>?
    @State private var copiedToken: String?
    @State private var showFolderPicker = false

    var body: some View {
        Form {
            Section("Header") {
                TextEditor(text: $headerText).frame(minHeight: 100)
            }
            Section("Footer") {
                TextEditor(text: $footerText).frame(minHeight: 100)
            }
            Section("Attachments") {
                Button {
                    showFolderPicker = true
                } label: {
                    HStack {
                        Text("Attachments folder")
                        Spacer()
                        Text(attachmentFolderDisplayPath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
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
        .navigationTitle("Templates & Defaults")
        .navigationBarTitleDisplayMode(.inline)
        .task { load() }
        .onChange(of: headerText) { _, _ in scheduleSave() }
        .onChange(of: footerText) { _, _ in scheduleSave() }
        .fileImporter(
            isPresented: $showFolderPicker,
            allowedContentTypes: [.folder]
        ) { result in
            switch result {
            case .success(let url):
                if let bookmark = try? url.bookmarkData(
                    options: [.minimalBookmark],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                ) {
                    settingsStore.update { $0.attachmentFolderBookmark = bookmark }
                    attachmentFolderDisplayPath = url.path
                }
            case .failure:
                break
            }
        }
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

    private func resolveDisplayPath() {
        guard let data = settingsStore.settings.attachmentFolderBookmark else {
            attachmentFolderDisplayPath = "Default"
            return
        }
        var stale = false
        if let url = try? URL(resolvingBookmarkData: data, relativeTo: nil, bookmarkDataIsStale: &stale) {
            attachmentFolderDisplayPath = url.lastPathComponent
        } else {
            attachmentFolderDisplayPath = "Default"
        }
    }

    private var placeholdersHint: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Tap a token to copy it. Drop tokens into the header or footer.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(Self.placeholderHints, id: \.token) { hint in
                Button { copyToken(hint.token) } label: {
                    HStack {
                        Text(hint.token).font(.system(.caption, design: .monospaced))
                        Spacer()
                        Text(hint.descriptionText).font(.caption).foregroundStyle(.secondary)
                        Image(systemName: copiedToken == hint.token ? "checkmark" : "doc.on.doc")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func copyToken(_ token: String) {
        UIPasteboard.general.string = token
        copiedToken = token
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            if copiedToken == token { copiedToken = nil }
        }
    }

    private struct PlaceholderHint { let token: String; let descriptionText: String }
    private static let placeholderHints: [PlaceholderHint] = [
        .init(token: "{{sender_name}}", descriptionText: "Sender display name"),
        .init(token: "{{sender_email}}", descriptionText: "From address"),
        .init(token: "{{recipient_email}}", descriptionText: "Recipient's email"),
        .init(token: "{{app_name}}", descriptionText: "App name"),
        .init(token: "{{issue_title}}", descriptionText: "Issue title"),
        .init(token: "{{issue_url}}", descriptionText: "Issue URL"),
        .init(token: "{{feedback_body}}", descriptionText: "Original feedback description"),
        .init(token: "{{date}}", descriptionText: "Current date and time")
    ]
}
#endif
