#if os(macOS)
import SwiftUI
import AppKit

struct EmailSettingsView: View {
    @Environment(MailAccountStore.self) private var store
    @Environment(ActivityLog.self) private var activityLog
    @Environment(MailSyncCoordinatorHolder.self) private var coordinatorHolder: MailSyncCoordinatorHolder?

    @State private var preset: SMTPCredentials.Preset = .gmail
    @State private var host: String = ""
    @State private var port: String = "587"
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var senderName: String = ""

    @State private var imapHost: String = ""
    @State private var imapPort: String = "993"
    @State private var imapUsername: String = ""
    @State private var imapPassword: String = ""

    @State private var pollingEnabled: Bool = true
    @State private var pollIntervalMinutes: Int = 5
    @State private var attachmentFolderBookmarkData: Data? = nil
    @State private var attachmentFolderDisplayPath: String = "Default (~/Downloads)"

    @State private var saveStatus: String?
    @State private var copiedToken: String?

    @State private var headerText: String = ""
    @State private var footerText: String = ""
    @State private var testStatus: String?

    @State private var didLoad = false
    @State private var saveTask: Task<Void, Never>?

    var body: some View {
        Form {
            Section("Provider") {
                Picker("Preset", selection: $preset) {
                    ForEach(SMTPCredentials.Preset.allCases) { p in
                        Text(p.displayName).tag(p)
                    }
                }
                .onChange(of: preset) { _, new in
                    applyPresetDefaults(new)
                    scheduleSave()
                }
            }

            Section("Credentials") {
                TextField("Host", text: $host)
                    .disabled(preset != .custom)
                TextField("Port", text: $port)
                    .disabled(preset != .custom)
                TextField("Username / from address", text: $username)
                SecureField("App password", text: $password)
                if preset == .gmail {
                    HStack(spacing: 6) {
                        Text("Gmail requires a 16-character app password (not your account password). 2-Step Verification must be on.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Button("Get app password") { openGmailAppPasswords() }
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                }
                TextField("Sender display name", text: $senderName)
            }

            Section("Receiving (IMAP)") {
                TextField("IMAP host", text: $imapHost)
                    .disabled(preset != .custom)
                TextField("IMAP port", text: $imapPort)
                    .disabled(preset != .custom)
                TextField("IMAP username", text: $imapUsername)
                SecureField("IMAP password", text: $imapPassword)
                Text("Used when receiving replies (Plan B). Defaults to the SMTP username; override only if your IMAP login differs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Auto-fetch replies", isOn: $pollingEnabled)
                    .onChange(of: pollingEnabled) { _, _ in scheduleSave() }

                Stepper(
                    "Every \(pollIntervalMinutes) minute\(pollIntervalMinutes == 1 ? "" : "s")",
                    value: $pollIntervalMinutes,
                    in: 1...60
                )
                .onChange(of: pollIntervalMinutes) { _, _ in scheduleSave() }

                HStack {
                    Button("Attachments folder…") { pickAttachmentFolder() }
                    Text(attachmentFolderDisplayPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Button("Test IMAP connection") { testIMAPConnection() }
                    .disabled(imapHost.isEmpty || imapUsername.isEmpty || imapPassword.isEmpty)
            }

            Section("Header") {
                TextEditor(text: $headerText)
                    .font(.body)
                    .frame(minHeight: 120)
            }

            Section("Footer") {
                TextEditor(text: $footerText)
                    .font(.body)
                    .frame(minHeight: 120)
            }

            Section("Placeholders") {
                placeholdersHint
            }

            Section("Tools") {
                HStack {
                    Button("Test Connection") { testConnection() }
                        .disabled(username.isEmpty || host.isEmpty || password.isEmpty)
                    Button("Preview") { showPreview() }
                    Button("Refresh now") {
                        Task { await coordinatorHolder?.coordinator?.pollNow() }
                    }
                    .disabled(coordinatorHolder?.coordinator == nil)
                    Spacer()
                    if let testStatus { Text(testStatus).foregroundStyle(.secondary) }
                    if let saveStatus {
                        Text(saveStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task { await loadFromSettings() }
        .onChange(of: host) { _, _ in scheduleSave() }
        .onChange(of: port) { _, _ in scheduleSave() }
        .onChange(of: username) { _, _ in scheduleSave() }
        .onChange(of: password) { _, _ in scheduleSave() }
        .onChange(of: senderName) { _, _ in scheduleSave() }
        .onChange(of: headerText) { _, _ in scheduleSave() }
        .onChange(of: footerText) { _, _ in scheduleSave() }
        .onChange(of: imapHost) { _, _ in scheduleSave() }
        .onChange(of: imapPort) { _, _ in scheduleSave() }
        .onChange(of: imapUsername) { _, _ in scheduleSave() }
        .onChange(of: imapPassword) { _, _ in scheduleSave() }
        .onAppear { resolveDisplayPath() }
    }

    private func applyPresetDefaults(_ p: SMTPCredentials.Preset) {
        let d = SMTPCredentials.defaults(for: p)
        host = d.host
        port = String(d.port)
        let imap = MailAccountMigration.imapDefaults(for: p)
        imapHost = imap.host
        imapPort = String(imap.port)
    }

    private func loadFromSettings() async {
        if let acc = store.account, !acc.smtpUsername.isEmpty {
            preset = acc.preset
            host = acc.smtpHost
            port = String(acc.smtpPort)
            username = acc.smtpUsername
            senderName = acc.senderName
            imapHost = acc.imapHost
            imapPort = String(acc.imapPort)
            imapUsername = acc.imapUsername
            pollingEnabled = acc.pollingEnabled
            pollIntervalMinutes = max(1, min(60, acc.pollIntervalSeconds / 60))
            attachmentFolderBookmarkData = acc.attachmentFolderBookmark
        } else {
            applyPresetDefaults(preset)
        }
        if let pw = await KeychainService.loadSMTPPassword() {
            password = pw
        }
        if let pw = await KeychainService.loadIMAPPassword() {
            imapPassword = pw
        }
        headerText = MailTemplatePlainText.from(html: store.account?.templateHeaderHTML ?? "")
        footerText = MailTemplatePlainText.from(html: store.account?.templateFooterHTML ?? "")
        resolveDisplayPath()
        didLoad = true
    }

    private func scheduleSave() {
        guard didLoad else { return }
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if Task.isCancelled { return }
            await save()
        }
    }

    @MainActor
    private func save() async {
        let headerHTML = MailTemplatePlainText.toHTML(headerText)
        let footerHTML = MailTemplatePlainText.toHTML(footerText)
        store.upsert { acc in
            acc.presetRaw = preset.rawValue
            acc.smtpHost = host
            acc.smtpPort = Int(port) ?? 587
            acc.smtpUsername = username
            acc.senderName = senderName
            acc.imapHost = imapHost
            acc.imapPort = Int(imapPort) ?? 993
            acc.imapUsername = imapUsername.isEmpty ? username : imapUsername
            acc.templateHeaderHTML = headerHTML
            acc.templateFooterHTML = footerHTML
            acc.pollingEnabled = pollingEnabled
            acc.pollIntervalSeconds = pollIntervalMinutes * 60
            acc.attachmentFolderBookmark = attachmentFolderBookmarkData
        }
        let smtpOk = await KeychainService.saveSMTPPassword(password)
        let imapOk = imapPassword.isEmpty
            ? true
            : await KeychainService.saveIMAPPassword(imapPassword)
        saveStatus = (smtpOk && imapOk) ? "Saved" : "Saved settings, but Keychain failed"
    }

    // MARK: - Placeholders hint

    private var placeholdersHint: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Drop these tokens into the header or footer — they'll be replaced when the email is sent. Click a token to copy it.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Grid(alignment: .leadingFirstTextBaseline,
                 horizontalSpacing: 10, verticalSpacing: 2) {
                ForEach(Self.placeholderHints, id: \.token) { hint in
                    GridRow {
                        Button {
                            copyToken(hint.token)
                        } label: {
                            HStack(spacing: 4) {
                                Text(hint.token)
                                    .font(.system(.caption, design: .monospaced))
                                Image(systemName: copiedToken == hint.token
                                      ? "checkmark"
                                      : "doc.on.doc")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Copy \(hint.token)")
                        Text(hint.descriptionText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.top, 4)
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

    private struct PlaceholderHint {
        let token: String
        let descriptionText: String
    }

    private static let placeholderHints: [PlaceholderHint] = [
        .init(token: "{{sender_name}}",     descriptionText: "Your sender display name"),
        .init(token: "{{sender_email}}",    descriptionText: "Your from address"),
        .init(token: "{{recipient_email}}", descriptionText: "The recipient's email"),
        .init(token: "{{app_name}}",        descriptionText: "App the issue belongs to"),
        .init(token: "{{issue_title}}",     descriptionText: "Title of the issue"),
        .init(token: "{{issue_url}}",       descriptionText: "Link to the issue"),
        .init(token: "{{date}}",            descriptionText: "Current date and time")
    ]

    // MARK: - Gmail helper

    private func openGmailAppPasswords() {
        var components = URLComponents(string: "https://myaccount.google.com/apppasswords")!
        let trimmed = username.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("@") {
            components.queryItems = [URLQueryItem(name: "authuser", value: trimmed)]
        }
        if let url = components.url {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Test Connection

    private func testConnection() {
        let freshCreds = SMTPCredentials(
            preset: preset,
            host: host,
            port: Int(port) ?? 587,
            username: username,
            senderName: senderName
        )
        let id = activityLog.start(kind: .testConnection, title: "\(freshCreds.host):\(freshCreds.port)")
        Task {
            #if canImport(SwiftMail)
            do {
                let sender = MailSender()
                try await sender.testConnection(freshCreds, password: password)
                activityLog.finish(id, status: .success, detail: "Login OK")
                testStatus = "Connection OK"
            } catch {
                activityLog.finish(id, status: .failure, detail: error.localizedDescription)
                testStatus = "Failed: \(error.localizedDescription)"
            }
            #else
            activityLog.finish(id, status: .failure, detail: "SwiftMail not available")
            #endif
        }
    }

    // MARK: - Preview

    private func showPreview() {
        #if canImport(SwiftMail)
        let composer = MailComposer()
        let creds = currentCredentialsFromForm()
        let context = PlaceholderContext(
            sender: creds,
            recipient: "preview@example.com",
            appName: "Preview App",
            issueTitle: "Sample issue",
            issueURL: URL(string: "https://github.com/example/repo/issues/1"),
            date: Date()
        )
        let template = MailTemplate(
            headerHTML: MailTemplatePlainText.toHTML(headerText),
            footerHTML: MailTemplatePlainText.toHTML(footerText)
        )
        let draft = DraftMessage(
            recipient: "preview@example.com",
            subject: "Preview",
            body: NSAttributedString(string: "[Body goes here]")
        )
        let email = composer.compose(draft: draft, context: context, template: template)
        if let html = email.htmlBody, let url = writePreviewHTML(html) {
            NSWorkspace.shared.open(url)
        }
        #endif
    }

    private func currentCredentialsFromForm() -> SMTPCredentials {
        SMTPCredentials(
            preset: preset,
            host: host,
            port: Int(port) ?? 587,
            username: username,
            senderName: senderName
        )
    }

    private func writePreviewHTML(_ html: String) -> URL? {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppFeedback-Preview", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("preview-\(UUID().uuidString).html")
        do {
            try html.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    // MARK: - Test IMAP Connection

    private func testIMAPConnection() {
        let id = activityLog.start(kind: .testConnection, title: "\(imapHost):\(imapPort) (IMAP)")
        Task {
            #if canImport(SwiftMail)
            let client = IMAPClient(
                host: imapHost,
                port: Int(imapPort) ?? 993,
                username: imapUsername.isEmpty ? username : imapUsername,
                password: imapPassword
            )
            do {
                try await client.testConnection()
                activityLog.finish(id, status: .success, detail: "IMAP login OK")
                testStatus = "IMAP connection OK"
            } catch {
                activityLog.finish(id, status: .failure, detail: error.localizedDescription)
                testStatus = "IMAP failed: \(error.localizedDescription)"
            }
            #else
            activityLog.finish(id, status: .failure, detail: "SwiftMail not available")
            #endif
        }
    }

    // MARK: - Attachment Folder Picker

    private func pickAttachmentFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Pick a folder to save downloaded attachments"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let bookmark = try url.bookmarkData(
                    options: [.withSecurityScope],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
                attachmentFolderBookmarkData = bookmark
                attachmentFolderDisplayPath = url.path
                scheduleSave()
            } catch {
                // Leave previous bookmark unchanged on failure
            }
        }
    }

    // MARK: - Resolve bookmark display path

    private func resolveDisplayPath() {
        guard let data = attachmentFolderBookmarkData else {
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
}
#endif
