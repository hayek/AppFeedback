#if os(macOS)
import SwiftUI
import AppKit

struct EmailSettingsView: View {
    @Environment(MailAccountStore.self) private var store
    @Environment(ActivityLog.self) private var activityLog
    @Environment(MailSyncCoordinatorHolder.self) private var coordinatorHolder: MailSyncCoordinatorHolder?
    @Environment(MailThreadStore.self) private var threadStore
    @Environment(MailAccountLocalStateStore.self) private var localStateStore

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

    @State private var showAdvanced: Bool = false
    @State private var separateIMAPCreds: Bool = false
    @State private var showResetConfirm: Bool = false

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

            Section("Account") {
                TextField("Email address", text: $username)
                HStack {
                    SecureField("Password", text: $password)
                    pasteButton { password = preset.sanitize(password: $0) }
                }
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
            }

            Section {
                DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                    Text("Hosts and ports are filled from the provider preset. Override only if your provider needs custom values or your IMAP login differs from your SMTP login.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    LabeledContent("SMTP host") {
                        TextField("", text: $host).disabled(preset != .custom)
                    }
                    LabeledContent("SMTP port") {
                        TextField("", text: $port).disabled(preset != .custom)
                    }
                    LabeledContent("IMAP host") {
                        TextField("", text: $imapHost).disabled(preset != .custom)
                    }
                    LabeledContent("IMAP port") {
                        TextField("", text: $imapPort).disabled(preset != .custom)
                    }

                    Toggle("Use a different IMAP login", isOn: $separateIMAPCreds)
                    if separateIMAPCreds {
                        TextField("IMAP username", text: $imapUsername)
                        HStack {
                            SecureField("IMAP password", text: $imapPassword)
                            pasteButton { imapPassword = preset.sanitize(password: $0) }
                        }
                    }
                }
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
                    Button("Reset…", role: .destructive) { showResetConfirm = true }
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
        .onChange(of: password) { _, new in
            let cleaned = preset.sanitize(password: new)
            if cleaned != new { password = cleaned } else { scheduleSave() }
        }
        .onChange(of: senderName) { _, _ in scheduleSave() }
        .onChange(of: headerText) { _, _ in scheduleSave() }
        .onChange(of: footerText) { _, _ in scheduleSave() }
        .onChange(of: imapHost) { _, _ in scheduleSave() }
        .onChange(of: imapPort) { _, _ in scheduleSave() }
        .onChange(of: imapUsername) { _, _ in scheduleSave() }
        .onChange(of: imapPassword) { _, new in
            let cleaned = preset.sanitize(password: new)
            if cleaned != new { imapPassword = cleaned } else { scheduleSave() }
        }
        .onAppear { resolveDisplayPath() }
        .alert("Reset email settings?", isPresented: $showResetConfirm) {
            Button("Cancel", role: .cancel) { }
            Button("Reset", role: .destructive) { Task { await resetAll() } }
        } message: {
            Text("This clears your email account, passwords, header, and footer from this device and iCloud Keychain.")
        }
    }

    @ViewBuilder
    private func pasteButton(assign: @escaping (String) -> Void) -> some View {
        Button {
            if let s = NSPasteboard.general.string(forType: .string) { assign(s) }
        } label: {
            Image(systemName: "doc.on.clipboard")
        }
        .buttonStyle(.borderless)
        .help("Paste password")
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
        // Re-fetch from the SwiftData store before reading. CloudKit may have synced
        // a record from another device while this store cached `nil` (e.g. right after
        // Reset, or first launch on a fresh install when iCloud already has settings).
        store.reload()
        if let acc = store.account, !acc.smtpUsername.isEmpty {
            preset = acc.preset
            host = acc.smtpHost
            port = String(acc.smtpPort)
            username = acc.smtpUsername
            senderName = acc.senderName
            imapHost = acc.imapHost
            imapPort = String(acc.imapPort)
            imapUsername = acc.imapUsername
            separateIMAPCreds = !acc.imapUsername.isEmpty && acc.imapUsername != acc.smtpUsername
            if separateIMAPCreds { showAdvanced = true }
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
        // Heal stale IMAP keychain when the user hasn't opted into separate creds:
        // an old setup may have left the IMAP slot empty or out-of-sync with SMTP, and
        // since save() only runs on field changes, nothing else would fix it.
        if !separateIMAPCreds, !password.isEmpty, imapPassword != password {
            _ = await KeychainService.saveIMAPPassword(password)
            imapPassword = password
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
        // When the user hasn't enabled the separate-IMAP-login override, mirror the SMTP
        // username/password to IMAP so a single set of credentials covers both protocols.
        let effectiveIMAPUsername = separateIMAPCreds && !imapUsername.isEmpty ? imapUsername : username
        let effectiveIMAPPassword = separateIMAPCreds && !imapPassword.isEmpty ? imapPassword : password
        store.upsert { acc in
            acc.presetRaw = preset.rawValue
            acc.smtpHost = host
            acc.smtpPort = Int(port) ?? 587
            acc.smtpUsername = username
            acc.senderName = senderName
            acc.imapHost = imapHost
            acc.imapPort = Int(imapPort) ?? 993
            acc.imapUsername = effectiveIMAPUsername
            acc.templateHeaderHTML = headerHTML
            acc.templateFooterHTML = footerHTML
            acc.pollingEnabled = pollingEnabled
            acc.pollIntervalSeconds = pollIntervalMinutes * 60
            acc.attachmentFolderBookmark = attachmentFolderBookmarkData
        }
        let smtpOk = await KeychainService.saveSMTPPassword(password)
        let imapOk = await KeychainService.saveIMAPPassword(effectiveIMAPPassword)
        saveStatus = (smtpOk && imapOk) ? "Saved" : "Saved settings, but Keychain failed"
        // Intentionally don't kick the coordinator here. Each keystroke fires this debounced
        // save, which used to trigger a full poll (backfill + listInbox) — backfill fails
        // mid-typing when creds are still incomplete. The user will hit "Refresh now" or
        // wait for the regular poll interval; both pick up the new creds via fresh client.
    }

    @MainActor
    private func resetAll() async {
        // Suppress the onChange-triggered scheduleSave race: clearing the form below would
        // otherwise debounce-save a fresh empty MailAccount + empty Keychain entries right
        // back into existence.
        didLoad = false
        saveTask?.cancel()
        await coordinatorHolder?.coordinator?.stop()
        threadStore.deleteAll()
        localStateStore.deleteAll()
        store.deleteAccount()
        await KeychainService.deleteSMTPPassword()
        await KeychainService.deleteIMAPPassword()
        preset = .gmail
        applyPresetDefaults(.gmail)
        username = ""
        password = ""
        senderName = ""
        imapUsername = ""
        imapPassword = ""
        separateIMAPCreds = false
        showAdvanced = false
        headerText = ""
        footerText = ""
        pollingEnabled = true
        pollIntervalMinutes = 5
        attachmentFolderBookmarkData = nil
        attachmentFolderDisplayPath = "Default (~/Downloads)"
        testStatus = nil
        saveStatus = "Settings cleared"
        didLoad = true
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
