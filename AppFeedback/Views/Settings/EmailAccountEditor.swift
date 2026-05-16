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
    @State private var testStatus: TestStatus = .idle
    @State private var showRemoveConfirm: Bool = false
    @State private var isRefreshing: Bool = false
    @State private var didLoad = false
    @State private var saveTask: Task<Void, Never>?

    private enum TestStatus: Equatable {
        case idle
        case running
        case success
        case failure(message: String)
    }

    private var account: MailAccount? { store.account(id: accountID) }
    private var isDefault: Bool { account?.isDefaultSender ?? false }
    private var hasCredentialsForTest: Bool {
        !username.isEmpty && !host.isEmpty && !password.isEmpty
    }

    var body: some View {
        Form {
            providerSection
            accountSection
            syncSection
            advancedSection
            actionsSection
            removeSection
            if let saveStatus {
                Section {
                    Label(saveStatus, systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .symbolRenderingMode(.hierarchical)
                }
            }
        }
        .formStyle(.grouped)
        .task(id: accountID) { await load() }
        .onChange(of: host)     { _, _ in scheduleSave() }
        .onChange(of: port)     { _, _ in scheduleSave() }
        .onChange(of: username) { _, _ in scheduleSave() }
        .onChange(of: password) { _, _ in scheduleSave() }
        .onChange(of: senderName) { _, _ in scheduleSave() }
        .onChange(of: imapHost) { _, _ in scheduleSave() }
        .onChange(of: imapPort) { _, _ in scheduleSave() }
        .onChange(of: imapUsername) { _, _ in scheduleSave() }
        .onChange(of: imapPassword) { _, _ in scheduleSave() }
        .alert("Remove this account?", isPresented: $showRemoveConfirm) {
            Button("Cancel", role: .cancel) { }
            Button("Remove", role: .destructive) { Task { await removeAccount() } }
        } message: {
            Text("Mail for this account stays in your inbox/sent folders. The credentials and per-account state are removed from this device.")
        }
    }

    // MARK: - Sections

    private var providerSection: some View {
        Section {
            LabeledContent("Service") {
                HStack(spacing: 8) {
                    MailProviderBadge(preset: preset, size: 18)
                    Picker("", selection: $preset) {
                        ForEach(SMTPCredentials.Preset.allCases) { p in
                            Text(p.displayName).tag(p)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
            }
            .onChange(of: preset) { _, new in applyPresetDefaults(new); scheduleSave() }
        } footer: {
            if preset == .custom {
                Text("Configure SMTP and IMAP hosts under Advanced.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var accountSection: some View {
        Section("Account") {
            TextField("Email address", text: $username, prompt: Text("you@example.com"))
                .textContentType(.emailAddress)
            HStack(spacing: 6) {
                SanitizedPasswordField(
                    title: "Password",
                    prompt: Text(preset.passwordPrompt),
                    text: $password
                )
                pasteButton { password = preset.sanitize(password: $0) }
            }
            if let help = preset.help {
                MailProviderHintCard(
                    preset: preset,
                    help: help,
                    appPasswordURL: preset.appPasswordsURL(forEmail: username)
                )
            }
            TextField("Sender display name", text: $senderName,
                      prompt: Text("Shown to recipients"))
        }
    }

    private var syncSection: some View {
        Section("Sync") {
            Toggle(isOn: $pollingEnabled) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Auto-fetch replies")
                    Text("Check this mailbox on the shared poll interval.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .onChange(of: pollingEnabled) { _, _ in scheduleSave() }
        }
    }

    private var advancedSection: some View {
        Section {
            DisclosureGroup(isExpanded: $showAdvanced) {
                LabeledContent("SMTP host") {
                    TextField("", text: $host).disabled(preset != .custom)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("SMTP port") {
                    TextField("", text: $port).disabled(preset != .custom)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("IMAP host") {
                    TextField("", text: $imapHost).disabled(preset != .custom)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("IMAP port") {
                    TextField("", text: $imapPort).disabled(preset != .custom)
                        .multilineTextAlignment(.trailing)
                }
                Toggle("Use a different IMAP login", isOn: $separateIMAPCreds)
                if separateIMAPCreds {
                    TextField("IMAP username", text: $imapUsername)
                    HStack(spacing: 6) {
                        SanitizedPasswordField(
                            title: "IMAP password",
                            text: $imapPassword
                        )
                        pasteButton { imapPassword = preset.sanitize(password: $0) }
                    }
                }
            } label: {
                Text("Advanced")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.18)) { showAdvanced.toggle() }
                    }
            }
        }
    }

    private var actionsSection: some View {
        Section {
            // Test row
            Button {
                testConnection()
            } label: {
                actionRow(
                    icon: testIcon,
                    iconTint: testIconTint,
                    title: "Test Connection",
                    subtitle: testSubtitle,
                    progressVisible: testStatus == .running
                )
            }
            .buttonStyle(.plain)
            .disabled(!hasCredentialsForTest || testStatus == .running)

            // Refresh row
            Button {
                Task {
                    isRefreshing = true
                    await registry?.coordinator(for: accountID)?.pollNow()
                    isRefreshing = false
                }
            } label: {
                actionRow(
                    icon: isRefreshing ? nil : "arrow.triangle.2.circlepath",
                    iconTint: .accentColor,
                    title: "Refresh Mailbox",
                    subtitle: "Fetch new replies immediately.",
                    progressVisible: isRefreshing
                )
            }
            .buttonStyle(.plain)
            .disabled(registry?.coordinator(for: accountID) == nil || isRefreshing)

            // Set-as-default row
            if !isDefault {
                Button {
                    if let acc = account { store.setDefaultSender(acc) }
                } label: {
                    actionRow(
                        icon: "paperplane.circle.fill",
                        iconTint: .accentColor,
                        title: "Set as Default Sender",
                        subtitle: "New replies use this account by default."
                    )
                }
                .buttonStyle(.plain)
            }
        } header: {
            Text("Connection")
        }
    }

    private var removeSection: some View {
        Section {
            Button(role: .destructive) {
                showRemoveConfirm = true
            } label: {
                actionRow(
                    icon: "trash.fill",
                    iconTint: .red,
                    title: "Remove Account",
                    subtitle: "Deletes credentials from this device.",
                    titleTint: .red
                )
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Action row

    @ViewBuilder
    private func actionRow(
        icon: String?,
        iconTint: Color,
        title: String,
        subtitle: String,
        progressVisible: Bool = false,
        titleTint: Color? = nil
    ) -> some View {
        HStack(spacing: 12) {
            Group {
                if progressVisible {
                    ProgressView().controlSize(.small)
                        .frame(width: 22, height: 22)
                } else if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 16))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(iconTint)
                        .frame(width: 22, height: 22)
                } else {
                    Color.clear.frame(width: 22, height: 22)
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(titleTint ?? .primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
    }

    // MARK: - Test status helpers

    private var testIcon: String? {
        switch testStatus {
        case .running: return nil
        case .success: return "checkmark.circle.fill"
        case .failure: return "exclamationmark.triangle.fill"
        case .idle:    return "bolt.horizontal.circle.fill"
        }
    }

    private var testIconTint: Color {
        switch testStatus {
        case .success: return .green
        case .failure: return .orange
        default:       return .accentColor
        }
    }

    private var testSubtitle: String {
        switch testStatus {
        case .idle:               return "Sign in once to verify SMTP credentials."
        case .running:            return "Contacting \(host)…"
        case .success:            return "Last test succeeded."
        case .failure(let msg):   return "Last test failed: \(msg)"
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func pasteButton(assign: @escaping (String) -> Void) -> some View {
        Button {
            if let s = NSPasteboard.general.string(forType: .string) { assign(s) }
        } label: {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
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
        // Auto-hide the saved indicator after a beat.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            if saveStatus == "Saved" || saveStatus == "Saved settings, but Keychain failed" {
                withAnimation(.easeOut(duration: 0.25)) { saveStatus = nil }
            }
        }
    }

    @MainActor
    private func removeAccount() async {
        guard let acc = store.account(id: accountID) else { return }
        await store.deleteWithCredentials(acc)
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
        testStatus = .running
        let id = activityLog.start(kind: .testConnection, title: "\(freshCreds.host):\(freshCreds.port)")
        Task {
            #if canImport(SwiftMail)
            do {
                let sender = MailSender()
                try await sender.testConnection(freshCreds, password: password)
                activityLog.finish(id, status: .success, detail: "Login OK")
                withAnimation(.easeInOut(duration: 0.2)) { testStatus = .success }
            } catch {
                let friendly = MailErrorTranslator.describe(error, preset: preset)
                activityLog.finish(id, status: .failure, detail: friendly)
                withAnimation(.easeInOut(duration: 0.2)) {
                    testStatus = .failure(message: friendly)
                }
            }
            #else
            activityLog.finish(id, status: .failure, detail: "SwiftMail not available")
            withAnimation { testStatus = .failure(message: "SwiftMail not available") }
            #endif
        }
    }
}
#endif
