#if os(macOS)
import SwiftUI
import AppKit

struct EmailAccountEditor: View {
    let accountID: UUID

    @Environment(MailAccountStore.self) private var store
    @Environment(ActivityLog.self) private var activityLog
    @Environment(\.mailSyncCoordinatorRegistry) private var registry: MailSyncCoordinatorRegistry?

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
    @State private var separateIMAPCreds: Bool = false

    @State private var pollingEnabled: Bool = true
    @State private var showAdvanced: Bool = false
    @State private var saveStatus: String?
    @State private var testStatus: String?
    @State private var showRemoveConfirm: Bool = false
    @State private var didLoad = false
    @State private var saveTask: Task<Void, Never>?

    private var account: MailAccount? { store.account(id: accountID) }
    private var isDefault: Bool { account?.isDefaultSender ?? false }

    var body: some View {
        Form {
            Section("Provider") {
                Picker("Preset", selection: $preset) {
                    ForEach(SMTPCredentials.Preset.allCases) { p in
                        Text(p.displayName).tag(p)
                    }
                }
                .onChange(of: preset) { _, new in applyPresetDefaults(new); scheduleSave() }
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
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Button("Get app password") { openGmailAppPasswords() }
                            .buttonStyle(.link).font(.caption)
                    }
                }
                TextField("Sender display name", text: $senderName)
                Toggle("Auto-fetch replies", isOn: $pollingEnabled)
                    .onChange(of: pollingEnabled) { _, _ in scheduleSave() }
            }
            Section {
                DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                    LabeledContent("SMTP host") { TextField("", text: $host).disabled(preset != .custom) }
                    LabeledContent("SMTP port") { TextField("", text: $port).disabled(preset != .custom) }
                    LabeledContent("IMAP host") { TextField("", text: $imapHost).disabled(preset != .custom) }
                    LabeledContent("IMAP port") { TextField("", text: $imapPort).disabled(preset != .custom) }
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
            Section("Tools") {
                HStack {
                    Button("Test Connection") { testConnection() }
                        .disabled(username.isEmpty || host.isEmpty || password.isEmpty)
                    if !isDefault {
                        Button("Set as default") {
                            if let acc = account { store.setDefaultSender(acc) }
                        }
                    }
                    Button("Refresh now") {
                        Task { await registry?.coordinator(for: accountID)?.pollNow() }
                    }
                    .disabled(registry?.coordinator(for: accountID) == nil)
                    Spacer()
                    Button("Remove account…", role: .destructive) { showRemoveConfirm = true }
                    if let testStatus { Text(testStatus).foregroundStyle(.secondary).font(.caption) }
                    if let saveStatus { Text(saveStatus).font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
        .formStyle(.grouped)
        .task(id: accountID) { await load() }
        .onChange(of: host)     { _, _ in scheduleSave() }
        .onChange(of: port)     { _, _ in scheduleSave() }
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
        .alert("Remove this account?", isPresented: $showRemoveConfirm) {
            Button("Cancel", role: .cancel) { }
            Button("Remove", role: .destructive) { Task { await removeAccount() } }
        } message: {
            Text("Mail for this account stays in your inbox/sent folders. The credentials and per-account state are removed from this device.")
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

    private func load() async {
        store.reload()
        guard let acc = store.account(id: accountID) else { return }
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
        if let pw = await KeychainService.loadSMTPPassword(for: accountID) { password = pw }
        if let pw = await KeychainService.loadIMAPPassword(for: accountID) { imapPassword = pw }
        if !separateIMAPCreds, !password.isEmpty, imapPassword != password {
            _ = await KeychainService.saveIMAPPassword(password, for: accountID)
            imapPassword = password
        }
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
        let effectiveIMAPUsername = separateIMAPCreds && !imapUsername.isEmpty ? imapUsername : username
        let effectiveIMAPPassword = separateIMAPCreds && !imapPassword.isEmpty ? imapPassword : password
        store.update(id: accountID) { acc in
            acc.presetRaw = preset.rawValue
            acc.smtpHost = host
            acc.smtpPort = Int(port) ?? 587
            acc.smtpUsername = username
            acc.senderName = senderName
            acc.imapHost = imapHost
            acc.imapPort = Int(imapPort) ?? 993
            acc.imapUsername = effectiveIMAPUsername
            acc.pollingEnabled = pollingEnabled
        }
        let smtpOk = await KeychainService.saveSMTPPassword(password, for: accountID)
        let imapOk = await KeychainService.saveIMAPPassword(effectiveIMAPPassword, for: accountID)
        saveStatus = (smtpOk && imapOk) ? "Saved" : "Saved settings, but Keychain failed"
    }

    @MainActor
    private func removeAccount() async {
        guard let acc = store.account(id: accountID) else { return }
        await KeychainService.deleteSMTPPassword(for: accountID)
        await KeychainService.deleteIMAPPassword(for: accountID)
        store.delete(acc)
        registry?.syncWithAccounts()
    }

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

    private func openGmailAppPasswords() {
        var components = URLComponents(string: "https://myaccount.google.com/apppasswords")!
        let trimmed = username.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("@") {
            components.queryItems = [URLQueryItem(name: "authuser", value: trimmed)]
        }
        if let url = components.url { NSWorkspace.shared.open(url) }
    }
}
#endif
