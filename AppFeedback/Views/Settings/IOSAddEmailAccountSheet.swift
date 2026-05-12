#if os(iOS)
import SwiftUI

struct IOSAddEmailAccountSheet: View {
    @Environment(MailAccountStore.self) private var store
    @Environment(\.mailSyncCoordinatorRegistry) private var registry: MailSyncCoordinatorRegistry?
    @Environment(\.dismiss) private var dismiss

    @State private var preset: SMTPCredentials.Preset = .gmail
    @State private var email: String = ""
    @State private var password: String = ""
    @State private var senderName: String = ""

    var onCreated: (UUID) -> Void = { _ in }

    var body: some View {
        NavigationStack {
            Form {
                Section("Provider") {
                    Picker("Preset", selection: $preset) {
                        ForEach(SMTPCredentials.Preset.allCases) { Text($0.displayName).tag($0) }
                    }
                }
                Section("Account") {
                    TextField("Email address", text: $email)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $password)
                    TextField("Sender display name", text: $senderName)
                }
            }
            .navigationTitle("Add Email Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { Task { await saveAndDismiss() } }
                        .disabled(email.isEmpty || password.isEmpty)
                }
            }
        }
    }

    private func saveAndDismiss() async {
        let smtpDefaults = SMTPCredentials.defaults(for: preset)
        let imapDefaults = MailAccountMigration.imapDefaults(for: preset)
        let acc = store.add { a in
            a.presetRaw = preset.rawValue
            a.smtpHost = smtpDefaults.host
            a.smtpPort = smtpDefaults.port
            a.smtpUsername = email
            a.senderName = senderName
            a.imapHost = imapDefaults.host
            a.imapPort = imapDefaults.port
            a.imapUsername = email
        }
        _ = await KeychainService.saveSMTPPassword(password, for: acc.id)
        _ = await KeychainService.saveIMAPPassword(password, for: acc.id)
        registry?.syncWithAccounts()
        onCreated(acc.id)
        dismiss()
    }
}
#endif
