#if os(iOS)
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct IOSEmailSettingsView: View {
    @Environment(MailAccountStore.self) private var store
    @Environment(ActivityLog.self) private var activityLog
    @Environment(MailSyncCoordinatorHolder.self) private var coordinatorHolder: MailSyncCoordinatorHolder?
    @Environment(MailThreadStore.self) private var threadStore
    @Environment(MailAccountLocalStateStore.self) private var localStateStore

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
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(.emailAddress)
                HStack {
                    SecureField("Password", text: $password)
                    pasteButton { password = preset.sanitize(password: $0) }
                }
                if preset == .gmail {
                    Text("Gmail requires a 16-character app password (not your account password). 2-Step Verification must be on.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                TextField("Sender display name", text: $senderName)
            }

            Section {
                DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                    Text("Hosts and ports come from the provider preset. Override only if your provider needs custom values or your IMAP login differs from your SMTP login.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("SMTP host", text: $host)
                        .disabled(preset != .custom)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField("SMTP port", text: $port)
                        .disabled(preset != .custom)
                        .keyboardType(.numberPad)
                    TextField("IMAP host", text: $imapHost)
                        .disabled(preset != .custom)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField("IMAP port", text: $imapPort)
                        .disabled(preset != .custom)
                        .keyboardType(.numberPad)
                    Toggle("Use a different IMAP login", isOn: $separateIMAPCreds)
                    if separateIMAPCreds {
                        TextField("IMAP username", text: $imapUsername)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .keyboardType(.emailAddress)
                        HStack {
                            SecureField("IMAP password", text: $imapPassword)
                            pasteButton { imapPassword = preset.sanitize(password: $0) }
                        }
                    }
                }
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
                Button("Test connection") { testSMTPConnection() }
                    .disabled(host.isEmpty || username.isEmpty || password.isEmpty)
                #endif
                Button("Refresh now") {
                    Task { await coordinatorHolder?.coordinator?.pollNow() }
                }
                .disabled(coordinatorHolder?.coordinator == nil)
                Button("Reset…", role: .destructive) { showResetConfirm = true }
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
        .onChange(of: password) { _, new in
            let cleaned = preset.sanitize(password: new)
            if cleaned != new { password = cleaned } else { scheduleSave() }
        }
        .onChange(of: senderName) { _, _ in scheduleSave() }
        .onChange(of: imapHost) { _, _ in scheduleSave() }
        .onChange(of: imapPort) { _, _ in scheduleSave() }
        .onChange(of: imapUsername) { _, _ in scheduleSave() }
        .onChange(of: imapPassword) { _, new in
            let cleaned = preset.sanitize(password: new)
            if cleaned != new { imapPassword = cleaned } else { scheduleSave() }
        }
        .onChange(of: headerText) { _, _ in scheduleSave() }
        .onChange(of: footerText) { _, _ in scheduleSave() }
        .fileImporter(
            isPresented: $showFolderPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            handleFolderSelection(result)
        }
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
            if let s = UIPasteboard.general.string { assign(s) }
        } label: {
            Image(systemName: "doc.on.clipboard")
        }
        .buttonStyle(.borderless)
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
        // Don't restart the coordinator on every keystroke — partial credentials would
        // trigger backfill failures. The next regular poll or Refresh picks up the change.
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

    // MARK: - Reset

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
        attachmentFolderDisplayPath = "Default (Documents/Attachments)"
        testStatus = nil
        saveStatus = "Settings cleared"
        didLoad = true
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
