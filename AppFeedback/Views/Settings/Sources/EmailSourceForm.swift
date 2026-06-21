import Foundation
import Observation

/// Pure view-model for the email feedback-source form. Holds the editable fields and the
/// create-vs-edit decision; SwiftUI views (macOS + iOS) bind to it. No I/O here — the views own
/// store/Keychain writes so this stays unit-testable.
@MainActor
@Observable
final class EmailSourceFormModel {
    let productID: UUID
    /// nil ⇒ creating a new feedback inbox; non-nil ⇒ editing the product's existing inbox account.
    let existingAccountID: UUID?

    var preset: SMTPCredentials.Preset = .gmail
    var username: String = ""            // doubles as IMAP login + From
    var password: String = ""
    var senderName: String = ""
    var imapHost: String = ""
    var imapPort: String = "993"
    var smtpHost: String = ""
    var smtpPort: String = "587"
    var pollingEnabled: Bool = true

    init(productID: UUID, existingAccountID: UUID?) {
        self.productID = productID
        self.existingAccountID = existingAccountID
        applyPresetDefaults(.gmail)
    }

    var isEditing: Bool { existingAccountID != nil }

    /// Resolves the account UUID that `remove()` should delete.
    /// Checks `liveProductAccountID` first (covers accounts minted mid-session via
    /// Test Connection whose UUID is not in `existingAccountID`), then falls back to
    /// the id captured at form-init time.
    func resolvedAccountID(liveProductAccountID: UUID?) -> UUID? {
        liveProductAccountID ?? existingAccountID
    }

    var canTest: Bool {
        !username.isEmpty && !imapHost.isEmpty && !password.isEmpty
    }

    func applyPresetDefaults(_ p: SMTPCredentials.Preset) {
        preset = p
        let smtp = SMTPCredentials.defaults(for: p)
        smtpHost = smtp.host
        smtpPort = String(smtp.port)
        let imap = MailAccountMigration.imapDefaults(for: p)
        imapHost = imap.host
        imapPort = String(imap.port)
    }

    struct AccountValues {
        let presetRaw: String
        let imapHost: String
        let imapPort: Int
        let imapUsername: String
        let smtpHost: String
        let smtpPort: Int
        let smtpUsername: String
        let senderName: String
        let pollingEnabled: Bool
        let feedbackProductID: UUID
    }

    func effectiveAccountValues() -> AccountValues {
        AccountValues(
            presetRaw: preset.rawValue,
            imapHost: imapHost,
            imapPort: Int(imapPort) ?? 993,
            imapUsername: username,
            smtpHost: smtpHost,
            smtpPort: Int(smtpPort) ?? 587,
            smtpUsername: username,
            senderName: senderName,
            pollingEnabled: pollingEnabled,
            feedbackProductID: productID
        )
    }
}

import SwiftUI

/// Configures (or edits) a product's email feedback inbox: a MailAccount with
/// `feedbackProductID == product.id`, referenced by `Product.feedbackInboxAccountID`.
/// Replaces the Phase-2 stub with the full form: IMAP host/port/user/password + Preset,
/// Test Connection, create/edit/remove a feedback inbox account. Used on both macOS and iOS.
struct EmailSourceForm: View {
    let product: ProductConfig
    /// Optional external save trigger — set to `true` from outside (the sheet's "Add" button) to
    /// invoke `save()` on the form without duplicating logic.
    var externalSaveTrigger: Binding<Bool>?
    /// Outward binding the form keeps in sync with its can-save validity, so the sheet's "Add"
    /// button can enable/disable itself.
    var externalCanSave: Binding<Bool>?

    @Environment(MailAccountStore.self) private var accountStore
    @Environment(ProductStore.self) private var productStore
    @Environment(ActivityLog.self) private var activityLog
    @Environment(\.mailSyncCoordinatorRegistry) private var registry: MailSyncCoordinatorRegistry?
    @Environment(\.dismiss) private var dismiss

    @State private var model: EmailSourceFormModel
    @State private var testState: String = ""
    @State private var didLoad = false
    @State private var showRemoveConfirm = false
    @State private var showSetupHelp = false
    /// True once the form has been saved or explicitly removed in this session. Used by the
    /// onDisappear cleanup to distinguish a deliberate save from a cancel/navigate-away dismiss.
    @State private var didSaveOrRemove = false

    init(product: ProductConfig, externalSaveTrigger: Binding<Bool>? = nil, externalCanSave: Binding<Bool>? = nil) {
        self.product = product
        self.externalSaveTrigger = externalSaveTrigger
        self.externalCanSave = externalCanSave
        _model = State(initialValue: EmailSourceFormModel(
            productID: product.id,
            existingAccountID: product.feedbackInboxAccountID
        ))
    }

    /// True when a Remove button should be shown. Covers two cases:
    ///   1. Editing an existing inbox (model.isEditing): `existingAccountID` was non-nil at form init.
    ///   2. A new-inbox session where Test Connection already minted a live account linkage: the
    ///      product's `feedbackInboxAccountID` is now non-nil even though `model.existingAccountID` is nil.
    private var showRemoveButton: Bool {
        model.isEditing || liveAccountID != nil
    }

    /// The account ID currently live in the product store (may differ from model.existingAccountID
    /// when Test Connection mints a new account during this form session).
    private var liveAccountID: UUID? {
        productStore.products.first(where: { $0.id == product.id })?.feedbackInboxAccountID
    }

    var body: some View {
        Form {
            Section("Inbox") {
                Picker("Service", selection: Binding(get: { model.preset }, set: { model.applyPresetDefaults($0) })) {
                    ForEach(SMTPCredentials.Preset.allCases) { Text($0.displayName).tag($0) }
                }
                TextField("Inbox address",
                          text: Binding(get: { model.username }, set: { model.username = $0 }),
                          prompt: Text("feedback@yourapp.com"))
                    .textContentType(.emailAddress)
                    #if os(iOS)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif
                SanitizedPasswordField(
                    title: "Password",
                    prompt: Text(model.preset.passwordPrompt),
                    text: Binding(get: { model.password }, set: { model.password = model.preset.sanitize(password: $0) })
                )
                if let help = model.preset.help {
                    MailProviderHintCard(preset: model.preset, help: help,
                                         appPasswordURL: model.preset.appPasswordsURL(forEmail: model.username))
                }
                TextField("Sender display name",
                          text: Binding(get: { model.senderName }, set: { model.senderName = $0 }))
                howToSetUp
            }
            if model.preset == .custom {
                Section("Advanced") {
                    LabeledContent("IMAP host") {
                        TextField("", text: Binding(get: { model.imapHost }, set: { model.imapHost = $0 }))
                            .multilineTextAlignment(.trailing)
                            #if os(iOS)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            #endif
                    }
                    LabeledContent("IMAP port") {
                        TextField("", text: Binding(get: { model.imapPort }, set: { model.imapPort = $0 }))
                            .multilineTextAlignment(.trailing)
                            #if os(iOS)
                            .keyboardType(.numberPad)
                            #endif
                    }
                }
            }
            Section {
                Button("Test Connection") { Task { await testConnection() } }
                    .disabled(!model.canTest)
                if !testState.isEmpty { Text(testState).font(.caption).foregroundStyle(.secondary) }
            }
            if showRemoveButton {
                Section {
                    Button("Remove Email Source", role: .destructive) { showRemoveConfirm = true }
                }
            }
        }
        #if os(macOS)
        .formStyle(.grouped)
        #endif
        #if os(iOS)
        .navigationTitle("Email Feedback Inbox")
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await load(); externalCanSave?.wrappedValue = model.canTest }
        .onChange(of: model.canTest) { _, can in externalCanSave?.wrappedValue = can }
        .onChange(of: externalSaveTrigger?.wrappedValue ?? false) { _, triggered in
            if triggered {
                externalSaveTrigger?.wrappedValue = false
                Task { await save() }
            }
        }
        .onDisappear {
            // Cancel/navigate-away path: if a mid-session account was minted (Test Connection ran
            // on a new-inbox form, which linked a new MailAccount to the product) but the user
            // never hit Save or Remove, clean up the orphan now.
            guard !didSaveOrRemove, model.existingAccountID == nil else { return }
            if let orphanID = liveAccountID,
               let acc = accountStore.account(id: orphanID) {
                var cleared = product
                cleared.feedbackInboxAccountID = nil
                productStore.update(cleared)
                Task { await accountStore.deleteWithCredentials(acc) }
            }
        }
        .alert("Remove this email source?", isPresented: $showRemoveConfirm) {
            Button("Cancel", role: .cancel) { }
            Button("Remove", role: .destructive) { Task { await remove() } }
        } message: {
            Text("Stops fetching this inbox and removes its credentials from this device. Existing feedback issues stay on GitHub.")
        }
    }

    private func load() async {
        guard !didLoad,
              let id = product.feedbackInboxAccountID,
              let acc = accountStore.account(id: id) else {
            didLoad = true
            return
        }
        model.preset = acc.preset
        model.username = acc.imapUsername.isEmpty ? acc.smtpUsername : acc.imapUsername
        model.senderName = acc.senderName
        model.imapHost = acc.imapHost
        model.imapPort = String(acc.imapPort)
        model.smtpHost = acc.smtpHost
        model.smtpPort = String(acc.smtpPort)
        model.pollingEnabled = acc.pollingEnabled
        if let pw = await KeychainService.loadIMAPPassword(for: id) { model.password = pw }
        didLoad = true
    }

    /// Persists the account and product linkage WITHOUT dismissing the form.
    /// Returns the persisted account UUID, or nil if nothing changed.
    @MainActor @discardableResult private func persistAccount() async -> UUID? {
        let v = model.effectiveAccountValues()
        let accountID: UUID
        if let existing = model.existingAccountID {
            accountStore.update(id: existing) { acc in apply(v, to: acc) }
            accountID = existing
        } else if let alreadyCreated = productStore.products.first(where: { $0.id == product.id })?.feedbackInboxAccountID {
            // An account was already created this session (e.g. a previous "Test Connection" call).
            // Reuse the same UUID so we don't mint a second orphaned MailAccount + Keychain entry.
            accountStore.update(id: alreadyCreated) { acc in apply(v, to: acc) }
            accountID = alreadyCreated
        } else {
            let acc = accountStore.add { a in apply(v, to: a) }
            accountID = acc.id
        }
        _ = await KeychainService.saveIMAPPassword(model.password, for: accountID)
        _ = await KeychainService.saveSMTPPassword(model.password, for: accountID)
        // Point the product at the inbox account.
        var updated = product
        updated.feedbackInboxAccountID = accountID
        productStore.update(updated)
        registry?.syncWithAccounts()
        return accountID
    }

    @MainActor private func save() async {
        await persistAccount()
        didSaveOrRemove = true
        testState = "Saved."
        dismiss()
    }

    private func apply(_ v: EmailSourceFormModel.AccountValues, to acc: MailAccount) {
        acc.presetRaw = v.presetRaw
        acc.imapHost = v.imapHost; acc.imapPort = v.imapPort; acc.imapUsername = v.imapUsername
        acc.smtpHost = v.smtpHost; acc.smtpPort = v.smtpPort; acc.smtpUsername = v.smtpUsername
        acc.senderName = v.senderName
        acc.pollingEnabled = v.pollingEnabled
        acc.feedbackProductID = v.feedbackProductID
    }

    @MainActor private func testConnection() async {
        // Persist creds to a (possibly new) account first so IMAPClientProvider can read them.
        // Use persistAccount() (not save()) so the form stays open to display the test result.
        await persistAccount()
        guard let id = productStore.products.first(where: { $0.id == product.id })?.feedbackInboxAccountID
                    ?? model.existingAccountID else { return }
        let logID = activityLog.start(kind: .testConnection, title: "\(model.imapHost):\(model.imapPort)")
        #if canImport(SwiftMail)
        do {
            let provider = IMAPClientProvider(accountStore: accountStore, accountID: id)
            try await provider.testConnection()
            activityLog.finish(logID, status: .success, detail: "Login OK")
            testState = "Connection OK."
        } catch {
            activityLog.finish(logID, status: .failure, detail: error.localizedDescription)
            testState = "Failed: \(error.localizedDescription)"
        }
        #else
        activityLog.finish(logID, status: .failure, detail: "SwiftMail not available")
        testState = "SwiftMail not available."
        #endif
    }

    @MainActor private func remove() async {
        // Resolve the account ID via the model helper: checks the live product linkage first
        // (covers accounts minted mid-session by Test Connection whose UUID isn't in
        // model.existingAccountID), then falls back to the id captured at form-init time.
        let accountID = model.resolvedAccountID(liveProductAccountID: liveAccountID)
        var updated = product
        updated.feedbackInboxAccountID = nil
        productStore.update(updated)
        if let id = accountID, let acc = accountStore.account(id: id) {
            await accountStore.deleteWithCredentials(acc)
        }
        registry?.syncWithAccounts()
        didSaveOrRemove = true
        dismiss()
    }

    // MARK: - Setup help

    @ViewBuilder private var howToSetUp: some View {
        DisclosureGroup(isExpanded: $showSetupHelp) {
            VStack(alignment: .leading, spacing: 10) {
                mailStep(1, "Use a dedicated mailbox for feedback (e.g. feedback@yourapp.com, or a separate Gmail/iCloud address). Every email it receives becomes a feedback item; replies in the same thread attach as comments.")
                mailStep(2, "Pick your provider in Service above — the IMAP host and port fill in automatically. Choose Custom to type them yourself.")
                mailStep(3, "If the account uses two-factor sign-in, your normal password won't work over IMAP. Create an app-specific password:")
                if let url = model.preset.appPasswordsURL(forEmail: model.username) {
                    Link(destination: url) {
                        Label("Create an app password for \(model.preset.displayName)", systemImage: "key.fill")
                    }
                } else {
                    Text("Generate one in your email provider's account security settings.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                mailStep(4, "Enter the inbox address and paste the app password.")
                mailStep(5, "Custom providers only: enter the IMAP host and port from your provider's help docs.")
                mailStep(6, "Tap Test Connection to verify, then Save.")
            }
            .font(.callout)
            .padding(.vertical, 4)
        } label: {
            Text("How do I set this up?")
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { withAnimation { showSetupHelp.toggle() } }
        }
    }

    private func mailStep(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(n).")
                .font(.callout.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
