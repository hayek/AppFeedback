#if os(macOS)
import SwiftUI

struct AddEmailAccountSheet: View {
    @Environment(MailAccountStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var preset: SMTPCredentials.Preset = .gmail
    @State private var email: String = ""
    @State private var password: String = ""
    @State private var senderName: String = ""

    var onCreated: (UUID) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add email account").font(.title3).bold()
            Form {
                Picker("Provider", selection: $preset) {
                    ForEach(SMTPCredentials.Preset.allCases) { Text($0.displayName).tag($0) }
                }
                TextField("Email address", text: $email)
                SecureField("Password", text: $password)
                TextField("Sender display name", text: $senderName)
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add") { Task { await saveAndDismiss() } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(email.isEmpty || password.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
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
        onCreated(acc.id)
        dismiss()
    }
}
#endif
