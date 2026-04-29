#if os(macOS)
import SwiftUI
import AppKit

struct EmailSettingsView: View {
    @Environment(MailAccountStore.self) private var store
    @Environment(ActivityLog.self) private var activityLog

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
}
#endif
