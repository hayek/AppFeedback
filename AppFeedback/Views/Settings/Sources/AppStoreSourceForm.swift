import SwiftUI
import UniformTypeIdentifiers

/// Real App Store Connect setup form (Phase 3 — replaces the Phase-2 stub). Paste Issuer ID +
/// Key ID, import the `.p8` private key (macOS file picker AND iOS Files via `.fileImporter`), tap
/// **Test** to validate the key + load the app list, pick the app (or type its numeric id), then
/// **Save** to store the `.p8` in the Keychain (keyed by product id) and write the IDs onto the
/// product. Shows the per-source `lastSuccessAt`/`lastError` from the live coordinator.
struct AppStoreSourceForm: View {
    let store: ProductStore
    let product: ProductConfig
    var externalSaveTrigger: Binding<Bool>? = nil
    var externalCanSave: Binding<Bool>? = nil

    @Environment(AppStoreReviewCoordinatorRegistry.self) private var registry
    @Environment(ActivityLog.self) private var activityLog
    @Environment(\.dismiss) private var dismiss
    @State private var model = AppStoreSourceFormModel()
    @State private var showImporter = false
    @State private var lastSuccessAt: Date?
    @State private var lastError: String?
    @State private var showKeyHelp = false

    // The `.p8` UTI — a PEM text file. `.data` is the safe superset that always lets the Files
    // picker surface a `.p8` on iOS; we also accept the explicit extension type when available.
    private var p8Types: [UTType] {
        var types: [UTType] = [.data, .text]
        if let p8 = UTType(filenameExtension: "p8") { types.insert(p8, at: 0) }
        return types
    }

    var body: some View {
        Form {
            credentialsSection
            keySection
            appSection
            statusSection
        }
        .formStyle(.grouped)
        #if os(iOS)
        .navigationTitle("App Store")
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .fileImporter(isPresented: $showImporter, allowedContentTypes: p8Types) { result in
            // iOS Files returns a security-scoped URL; the model handles start/stopAccessing.
            if case .success(let url) = result { model.importPEM(from: url) }
        }
        .task {
            loadFields()
            if let pem = await KeychainService.loadASCKey(for: product.id) { model.pemText = pem }
            externalCanSave?.wrappedValue = model.canSave
            await refreshStatus()
        }
        .onChange(of: model.canSave) { _, can in externalCanSave?.wrappedValue = can }
        .onChange(of: externalSaveTrigger?.wrappedValue ?? false) { _, triggered in
            guard triggered else { return }
            externalSaveTrigger?.wrappedValue = false
            Task { await runSave(); dismiss() }
        }
    }

    private var credentialsSection: some View {
        Section("Credentials") {
            TextField("Issuer ID", text: $model.issuerID)
                .textContentType(.none)
                #if os(iOS)
                .autocapitalization(.none)
                #endif
            TextField("Key ID", text: $model.keyID)
                #if os(iOS)
                .autocapitalization(.none)
                #endif
        }
    }

    private var keySection: some View {
        Section {
            Button {
                showImporter = true
            } label: {
                Label(model.pemText.isEmpty ? "Import .p8 Key…" : "Replace .p8 Key…",
                      systemImage: "key.fill")
            }
            if !model.pemText.isEmpty {
                Text("Key loaded (\(model.pemText.count) bytes).").font(.caption).foregroundStyle(.secondary)
            }
            Button("Test") { Task { await runTest() } }
                .disabled(model.issuerID.isEmpty || model.keyID.isEmpty || model.pemText.isEmpty
                          || model.phase == .testing)
            testResultRow
            howToGetKeys
        } header: {
            Text("Private Key (.p8)")
        } footer: {
            Text("Your .p8 is stored only in your Keychain — never synced to GitHub.")
        }
    }

    @ViewBuilder private var howToGetKeys: some View {
        DisclosureGroup(isExpanded: $showKeyHelp) {
            VStack(alignment: .leading, spacing: 10) {
                SourceHelpStepRow(number: 1, text: "Open App Store Connect → Users and Access → Integrations.")
                Link(destination: URL(string: "https://appstoreconnect.apple.com/access/integrations/api")!) {
                    Label("Open Integrations in App Store Connect", systemImage: "arrow.up.right.square")
                }
                SourceHelpStepRow(number: 2, text: "First time only: click Request Access, agree to the terms, and Submit. The Account Holder must do this, then wait for approval.")
                SourceHelpStepRow(number: 3, text: "With Team Keys selected, copy the Issuer ID shown above the keys table (it's the same for your whole team) and paste it into Issuer ID above.")
                SourceHelpStepRow(number: 4, text: "Click Generate API Key (the ＋). Name it, and under Access choose Admin (or Customer Support) so it can read reviews and post your responses. Then Generate.")
                SourceHelpStepRow(number: 5, text: "Copy the new key's Key ID from its row and paste it into Key ID.")
                SourceHelpStepRow(number: 6, text: "Click Download API Key to save the .p8 file — Apple lets you download it only once. Then tap \u{201C}Import .p8 Key\u{2026}\u{201D} above.")
                SourceHelpStepRow(number: 7, text: "Back here, tap Test to validate and load your apps, pick the app, and Save.")
                Link(destination: URL(string: "https://developer.apple.com/documentation/appstoreconnectapi/creating-api-keys-for-app-store-connect-api")!) {
                    Label("Apple's guide: Creating API keys", systemImage: "book")
                }
            }
            .font(.callout)
            .padding(.vertical, 4)
        } label: {
            Text("How do I get these keys?")
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { withAnimation { showKeyHelp.toggle() } }
        }
    }

    @ViewBuilder private var testResultRow: some View {
        switch model.phase {
        case .idle:    EmptyView()
        case .testing: HStack { ProgressView(); Text("Testing…").foregroundStyle(.secondary) }
        case .valid:   Label("Key valid — \(model.discoveredApps.count) app(s) found.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed(let msg): Label(msg, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
        }
    }

    @ViewBuilder private var appSection: some View {
        Section {
            if model.discoveredApps.isEmpty {
                TextField("App Apple ID (numeric)", text: $model.manualAppID)
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
                Text("Run **Test** to pick from your apps, or paste the numeric App Store ID.").font(.caption).foregroundStyle(.secondary)
            } else {
                Picker("App", selection: $model.selectedAppID) {
                    ForEach(model.discoveredApps, id: \.id) { app in
                        Text("\(app.name) (\(app.bundleId))").tag(app.id as String?)
                    }
                }
            }
        } header: {
            Text("App")
        }
    }

    private var statusSection: some View {
        Section("Status") {
            LabeledContent("Last sync") {
                Text(lastSuccessAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Never")
                    .foregroundStyle(.secondary)
            }
            if let lastError {
                Label(lastError, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.caption)
            }
        }
    }

    // MARK: - Actions

    private func loadFields() {
        model.issuerID = product.appStoreIssuerID ?? ""
        model.keyID = product.appStoreKeyID ?? ""
        model.manualAppID = product.appStoreAppAppleID ?? ""
    }

    private func runTest() async {
        await model.test { issuer, kid, pem in
            AppStoreConnectClient(auth: AppStoreConnectAuth(issuerID: issuer, keyID: kid, p8PEM: pem),
                                  activityLog: activityLog)
        }
    }

    private func runSave() async {
        await model.save(productID: product.id, into: store)
        // Restart the coordinator so the new credentials take effect immediately.
        let configs = store.products.compactMap {
            ASCProductConfig.make(id: $0.id, owner: $0.owner, repo: $0.repo,
                                  issuerID: $0.appStoreIssuerID, keyID: $0.appStoreKeyID,
                                  appAppleID: $0.appStoreAppAppleID)
        }
        registry.restart(productID: product.id, configs: configs)
        await refreshStatus()
    }

    private func refreshStatus() async {
        if let status = await registry.status(productID: product.id) {
            lastSuccessAt = status.lastSuccessAt
            lastError = status.lastError
        }
    }
}
