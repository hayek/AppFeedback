#if os(macOS)
import SwiftUI

struct AddEmailAccountSheet: View {
    @Environment(MailAccountStore.self) private var store
    @Environment(\.mailSyncCoordinatorRegistry) private var registry: MailSyncCoordinatorRegistry?
    @Environment(\.dismiss) private var dismiss

    @State private var preset: SMTPCredentials.Preset = .gmail
    @State private var presetWasUserSet: Bool = false
    @State private var email: String = ""
    @State private var password: String = ""
    @State private var senderName: String = ""
    @State private var saving: Bool = false

    var onCreated: (UUID) -> Void = { _ in }

    private var canSubmit: Bool {
        !email.trimmingCharacters(in: .whitespaces).isEmpty &&
        !password.isEmpty &&
        !saving
    }

    var body: some View {
        VStack(spacing: 0) {
            form
            footer
        }
        .frame(width: 520, height: 560)
        .background(.windowBackground)
    }

    // MARK: - Sections

    private var heroSection: some View {
        Section {
            VStack(spacing: 14) {
                MailProviderBadge(preset: preset, size: 56)
                    .padding(.top, 12)
                    .animation(.spring(response: 0.35, dampingFraction: 0.72), value: preset)
                VStack(spacing: 4) {
                    Text("Add Mail Account")
                        .font(.system(size: 19, weight: .semibold))
                    Text("Connect a mailbox so replies can flow back into your issues.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 36)
                }
                .padding(.bottom, 6)
            }
            .frame(maxWidth: .infinity)
            .listRowBackground(Color.clear)
        }
    }

    private var form: some View {
        Form {
            heroSection
            Section("Provider") {
                Picker("Service", selection: presetUserBinding) {
                    ForEach(SMTPCredentials.Preset.allCases) { p in
                        Text(p.displayName).tag(p)
                    }
                }
                .pickerStyle(.menu)
            }
            Section("Sign in") {
                TextField("Email address", text: $email,
                          prompt: Text("you@example.com"))
                    .textContentType(.emailAddress)
                    .onChange(of: email) { _, new in autoDetectPreset(from: new) }
                SanitizedPasswordField(
                    title: "Password",
                    prompt: Text(preset.passwordPrompt),
                    text: $password
                )
                TextField("Sender display name", text: $senderName,
                          prompt: Text("Optional"))
            }
            if let help = preset.help {
                Section {
                    MailProviderHintCard(
                        preset: preset,
                        help: help,
                        appPasswordURL: preset.appPasswordsURL(forEmail: email)
                    )
                }
            }
        }
        .formStyle(.grouped)
    }

    /// Picker binding that flags any user interaction so future autodetects are skipped —
    /// once the user picks a provider, typing a different email shouldn't quietly switch it.
    private var presetUserBinding: Binding<SMTPCredentials.Preset> {
        Binding(get: { preset }, set: { new in
            preset = new
            presetWasUserSet = true
        })
    }

    /// Switches the preset to match the email's domain on first detection, so users
    /// don't sign in with the wrong provider preset and hit an authentication failure.
    private func autoDetectPreset(from email: String) {
        guard !presetWasUserSet,
              let detected = SMTPCredentials.Preset.detect(fromEmail: email),
              detected != preset
        else { return }
        preset = detected
    }

    private var footer: some View {
        HStack {
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Spacer()
            Button {
                Task { await saveAndDismiss() }
            } label: {
                HStack(spacing: 6) {
                    if saving {
                        ProgressView().controlSize(.small).tint(.white)
                    }
                    Text(saving ? "Adding…" : "Add Account")
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!canSubmit)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    // MARK: - Save

    private func saveAndDismiss() async {
        saving = true
        let smtpDefaults = SMTPCredentials.defaults(for: preset)
        let imapDefaults = MailAccountMigration.imapDefaults(for: preset)
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let acc = store.add { a in
            a.presetRaw = preset.rawValue
            a.smtpHost = smtpDefaults.host
            a.smtpPort = smtpDefaults.port
            a.smtpUsername = trimmedEmail
            a.senderName = senderName
            a.imapHost = imapDefaults.host
            a.imapPort = imapDefaults.port
            a.imapUsername = trimmedEmail
        }
        _ = await KeychainService.saveSMTPPassword(password, for: acc.id)
        _ = await KeychainService.saveIMAPPassword(password, for: acc.id)
        registry?.syncWithAccounts()
        saving = false
        onCreated(acc.id)
        dismiss()
    }

}
#endif
