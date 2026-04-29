#if os(iOS)
import SwiftUI
import UniformTypeIdentifiers

struct IOSEmailSettingsView: View {
    @Environment(MailAccountStore.self) private var store
    @Environment(ActivityLog.self) private var activityLog
    @Environment(MailSyncCoordinatorHolder.self) private var coordinatorHolder: MailSyncCoordinatorHolder?

    // SMTP form fields
    @State private var preset: SMTPCredentials.Preset = .gmail
    @State private var host: String = ""
    @State private var port: String = "587"
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var senderName: String = ""

    // IMAP form fields
    @State private var imapHost: String = ""
    @State private var imapPort: String = "993"
    @State private var imapUsername: String = ""
    @State private var imapPassword: String = ""

    // Templates
    @State private var headerText: String = ""
    @State private var footerText: String = ""

    // Polling + attachment folder
    @State private var pollingEnabled: Bool = true
    @State private var pollIntervalMinutes: Int = 5
    @State private var attachmentFolderBookmarkData: Data? = nil
    @State private var attachmentFolderDisplayPath: String = "Default (Documents/Attachments)"
    @State private var showFolderPicker = false

    // UI state
    @State private var saveStatus: String?
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

            Section("Sending (SMTP)") {
                TextField("Host", text: $host)
                    .disabled(preset != .custom)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                TextField("Port", text: $port)
                    .disabled(preset != .custom)
                    .keyboardType(.numberPad)
                TextField("Username / from address", text: $username)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(.emailAddress)
                SecureField("App password", text: $password)
                TextField("Sender display name", text: $senderName)
                if preset == .gmail {
                    Text("Gmail requires a 16-character app password (not your account password). 2-Step Verification must be on.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Receiving (IMAP)") {
                TextField("IMAP host", text: $imapHost)
                    .disabled(preset != .custom)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                TextField("IMAP port", text: $imapPort)
                    .disabled(preset != .custom)
                    .keyboardType(.numberPad)
                TextField("IMAP username", text: $imapUsername)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(.emailAddress)
                SecureField("IMAP password", text: $imapPassword)
                Text("Used when receiving replies. Defaults to the SMTP username.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Polling") {
                Toggle("Auto-fetch replies", isOn: $pollingEnabled)
                    .onChange(of: pollingEnabled) { _, _ in scheduleSave() }
                Stepper(
                    "Every \(pollIntervalMinutes) minute\(pollIntervalMinutes == 1 ? "" : "s")",
                    value: $pollIntervalMinutes,
                    in: 1...60
                )
                .onChange(of: pollIntervalMinutes) { _, _ in scheduleSave() }
            }

            Section("Attachments") {
                Button {
                    showFolderPicker = true
                } label: {
                    HStack {
                        Label("Attachments folder", systemImage: "folder")
                        Spacer()
                        Text(attachmentFolderDisplayPath)
                            .foregroundStyle(.secondary)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }

            Section("Header") {
                TextEditor(text: $headerText)
                    .frame(minHeight: 80)
            }

            Section("Footer") {
                TextEditor(text: $footerText)
                    .frame(minHeight: 80)
            }

            Section("Tools") {
                #if canImport(SwiftMail)
                Button("Test SMTP connection") { testSMTPConnection() }
                    .disabled(host.isEmpty || username.isEmpty || password.isEmpty)
                Button("Test IMAP connection") { testIMAPConnection() }
                    .disabled(imapHost.isEmpty || imapUsername.isEmpty || imapPassword.isEmpty)
                #endif
                Button("Refresh now") {
                    Task { await coordinatorHolder?.coordinator?.pollNow() }
                }
                .disabled(coordinatorHolder?.coordinator == nil)
                if let testStatus {
                    Text(testStatus)
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
                if let saveStatus {
                    Text(saveStatus)
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
            }
        }
        .navigationTitle("Email")
        .navigationBarTitleDisplayMode(.large)
        .task { await loadFromSettings() }
        .onChange(of: host) { _, _ in scheduleSave() }
        .onChange(of: port) { _, _ in scheduleSave() }
        .onChange(of: username) { _, _ in scheduleSave() }
        .onChange(of: password) { _, _ in scheduleSave() }
        .onChange(of: senderName) { _, _ in scheduleSave() }
        .onChange(of: imapHost) { _, _ in scheduleSave() }
        .onChange(of: imapPort) { _, _ in scheduleSave() }
        .onChange(of: imapUsername) { _, _ in scheduleSave() }
        .onChange(of: imapPassword) { _, _ in scheduleSave() }
        .onChange(of: headerText) { _, _ in scheduleSave() }
        .onChange(of: footerText) { _, _ in scheduleSave() }
        .fileImporter(
            isPresented: $showFolderPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            handleFolderSelection(result)
        }
    }

    // MARK: - Preset defaults

    private func applyPresetDefaults(_ p: SMTPCredentials.Preset) {
        let d = SMTPCredentials.defaults(for: p)
        host = d.host
        port = String(d.port)
        let imap = MailAccountMigration.imapDefaults(for: p)
        imapHost = imap.host
        imapPort = String(imap.port)
    }

    // MARK: - Load

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

    // MARK: - Save (debounced)

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

        // I6: Restart the sync coordinator so credential changes (including password fixes after
        // an authFailed lock) take effect immediately without requiring an app restart.
        Task { await coordinatorHolder?.coordinator?.start() }
    }

    // MARK: - Test SMTP

    private func testSMTPConnection() {
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

    // MARK: - Test IMAP

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

    // MARK: - Folder picker

    private func handleFolderSelection(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        do {
            let bookmark = try url.bookmarkData(
                options: [],
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

    // MARK: - Resolve bookmark display path

    private func resolveDisplayPath() {
        guard let data = attachmentFolderBookmarkData else {
            attachmentFolderDisplayPath = "Default (Documents/Attachments)"
            return
        }
        var stale = false
        if let url = try? URL(
            resolvingBookmarkData: data,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) {
            attachmentFolderDisplayPath = url.path
        } else {
            attachmentFolderDisplayPath = "Default (Documents/Attachments)"
        }
    }
}
#endif
