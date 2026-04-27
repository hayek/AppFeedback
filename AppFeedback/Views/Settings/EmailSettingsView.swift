#if os(macOS)
import SwiftUI

struct EmailSettingsView: View {
    @Environment(MailSettings.self) private var settings

    @State private var preset: SMTPCredentials.Preset = .gmail
    @State private var host: String = ""
    @State private var port: String = "587"
    @State private var useSTARTTLS: Bool = true
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var senderName: String = ""

    @State private var saveStatus: String?

    var body: some View {
        Form {
            Section("Provider") {
                Picker("Preset", selection: $preset) {
                    ForEach(SMTPCredentials.Preset.allCases) { p in
                        Text(p.displayName).tag(p)
                    }
                }
                .onChange(of: preset) { _, new in applyPresetDefaults(new) }
            }

            Section("Credentials") {
                TextField("Host", text: $host)
                    .disabled(preset != .custom)
                TextField("Port", text: $port)
                    .disabled(preset != .custom)
                if preset == .custom {
                    Toggle("Use STARTTLS (informational; SwiftMail derives TLS mode from port)",
                           isOn: $useSTARTTLS)
                }
                TextField("Username / from address", text: $username)
                SecureField("App password", text: $password)
                TextField("Sender display name", text: $senderName)
            }

            Section {
                HStack {
                    Button("Save") { save() }
                    Spacer()
                    if let saveStatus { Text(saveStatus).foregroundStyle(.secondary) }
                }
            }
        }
        .formStyle(.grouped)
        .task { await loadFromSettings() }
    }

    private func applyPresetDefaults(_ p: SMTPCredentials.Preset) {
        let d = SMTPCredentials.defaults(for: p)
        host = d.host
        port = String(d.port)
        useSTARTTLS = d.useSTARTTLS
    }

    private func loadFromSettings() async {
        if let creds = settings.credentials {
            preset = creds.preset
            host = creds.host
            port = String(creds.port)
            useSTARTTLS = creds.useSTARTTLS
            username = creds.username
            senderName = creds.senderName
        } else {
            applyPresetDefaults(preset)
        }
        if let pw = await KeychainService.loadSMTPPassword() {
            password = pw
        }
    }

    private func save() {
        let creds = SMTPCredentials(
            preset: preset,
            host: host,
            port: Int(port) ?? 587,
            useSTARTTLS: useSTARTTLS,
            username: username,
            password: password,
            senderName: senderName
        )
        settings.credentials = creds
        Task {
            await KeychainService.saveSMTPPassword(password)
            saveStatus = "Saved"
        }
    }
}
#endif
