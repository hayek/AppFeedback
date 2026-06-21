import SwiftUI

/// The detail pane of the Products settings tab (and the sheet opened from the sidebar
/// "Settings…" item). Evolved from `AddEditRepoView`: a **General** section (GitHub connection +
/// mirror/redact toggles) and a **Sources** section (SDK / App Store / Email).
struct ProductSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    var store: ProductStore
    var product: ProductConfig
    var embedInNavigation: Bool = false

    @State private var displayName = ""
    @State private var owner = ""
    @State private var repo = ""
    @State private var token = ""
    @State private var mirrorEmailsToGitHub = true
    @State private var redactEmailAddresses = true
    @State private var isSaving = false
    @State private var activeSheet: SourceSheet?
    @State private var appStoreSave = false
    @State private var appStoreCanSave = false
    @State private var emailSave = false
    @State private var emailCanSave = false

    private enum SourceSheet: Int, Identifiable { case appStore, email; var id: Int { rawValue } }

    /// Returns the live version of `product` from the store so reactive reads pick up saved changes.
    private var liveProduct: ProductConfig { store.products.first(where: { $0.id == product.id }) ?? product }

    var body: some View {
        platformContent
            .task { await populateFromExisting() }
    }

    @ViewBuilder
    private var platformContent: some View {
        #if os(iOS)
        if embedInNavigation {
            NavigationStack { form }
        } else {
            form
        }
        #else
        form
        #endif
    }

    private var form: some View {
        Form {
            generalSection
            sourcesSection
        }
        .formStyle(.grouped)
        .sheet(item: $activeSheet) { sheetContent(for: $0) }
        #if os(iOS)
        .navigationTitle(displayName.isEmpty ? "Product" : displayName)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private func populateFromExisting() async {
        displayName = product.displayName
        owner = product.owner
        repo = product.repo
        mirrorEmailsToGitHub = product.mirrorEmailsToGitHub
        redactEmailAddresses = product.redactEmailAddresses
        token = await KeychainService.load(for: product) ?? ""
    }

    // MARK: - General section

    @ViewBuilder
    private var generalSection: some View {
        Section("General") {
            TextField("Display Name", text: $displayName)
            LabeledContent("Repository") {
                Text("\(owner)/\(repo)")
                    .font(.body.monospaced())
                    .foregroundStyle(.secondary)
            }
            Toggle("Mirror emails to issue comments", isOn: $mirrorEmailsToGitHub)
            if mirrorEmailsToGitHub {
                Toggle("Redact sender email addresses", isOn: $redactEmailAddresses)
            }
            Button("Save Changes") { Task { await save() } }
                .disabled(isSaving)
        }
    }

    private func save() async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        var updated = product
        updated.displayName = displayName.trimmingCharacters(in: .whitespaces)
        updated.mirrorEmailsToGitHub = mirrorEmailsToGitHub
        updated.redactEmailAddresses = redactEmailAddresses
        if !token.isEmpty {
            await KeychainService.save(token: token.trimmingCharacters(in: .whitespaces), for: updated)
        }
        store.update(updated)
    }

    // MARK: - Sources section

    @ViewBuilder
    private var sourcesSection: some View {
        Section {
            // SDK — always on, informational.
            HStack {
                Label("SDK", systemImage: "wrench.and.screwdriver")
                Spacer()
                Text("Receiving issues from \(owner)/\(repo)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            // App Store / Email — presented as SHEETS, not NavigationLink pushes. Pushing a grouped
            // Form onto the NavigationStack nested in the Products NavigationSplitView detail triggers
            // an infinite AppKit relayout loop on macOS (NSView _layoutSubtreeWithOldSize ↔ NSHostingView
            // render), beachballing the app. A modal sheet renders in its own hosting context and avoids it.
            Button { openSource(.appStore) } label: {
                sourceRow(title: "App Store", systemImage: "apple.logo", status: liveProduct.appStoreSourceStatus)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            Button { openSource(.email) } label: {
                sourceRow(title: "Email", systemImage: "envelope", status: liveProduct.emailSourceStatus)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
        } header: {
            Text("Sources")
        } footer: {
            Text("Feedback can arrive from the AppFeedback SDK, App Store reviews, and a dedicated email inbox. All sources are synthesized into this product's GitHub repository.")
        }
    }

    private func sourceRow(title: String, systemImage: String, status: SourceStatus) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
            Spacer()
            Text(status == .configured ? "Configured" : "Off")
                .font(.footnote)
                .foregroundStyle(status == .configured ? .green : .secondary)
            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())   // make the whole row (incl. the Spacer) tappable
    }

    // MARK: - Source sheets

    /// macOS opens a real window (native chrome); iOS presents a sheet (which has a native nav bar).
    private func openSource(_ kind: SourceEditorRequest.Kind) {
        #if os(macOS)
        openWindow(id: "source-editor", value: SourceEditorRequest(productID: product.id, kind: kind))
        #else
        // Reset chrome state so a reopened sheet never shows stale Add/Save button state.
        appStoreSave = false; appStoreCanSave = false
        emailSave = false; emailCanSave = false
        activeSheet = (kind == .appStore) ? .appStore : .email
        #endif
    }

    @ViewBuilder
    private func sheetContent(for sheet: SourceSheet) -> some View {
        switch sheet {
        case .appStore:
            let primaryTitle = liveProduct.appStoreSourceStatus == .configured ? "Save" : "Add"
            chrome(title: "App Store", primaryTitle: primaryTitle, canAdd: appStoreCanSave, add: $appStoreSave) {
                AppStoreSourceForm(store: store, product: product,
                                   externalSaveTrigger: $appStoreSave, externalCanSave: $appStoreCanSave)
            }
        case .email:
            let primaryTitle = liveProduct.emailSourceStatus == .configured ? "Save" : "Add"
            chrome(title: "Email Feedback Inbox", primaryTitle: primaryTitle, canAdd: emailCanSave, add: $emailSave) {
                EmailSourceForm(product: product,
                                externalSaveTrigger: $emailSave, externalCanSave: $emailCanSave)
            }
        }
    }

    /// Modal chrome for a source form (iOS only): a NavigationStack with ✕ cancel and a primary
    /// action button (Add when new, Save when already configured) that drives the form via its
    /// external save trigger / validity bindings. macOS always opens a real SourceEditorWindow instead.
    @ViewBuilder
    private func chrome<C: View>(title: String, primaryTitle: String, canAdd: Bool, add: Binding<Bool>, @ViewBuilder _ content: () -> C) -> some View {
        NavigationStack {
            content()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button { activeSheet = nil } label: { Image(systemName: "xmark") }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(primaryTitle) { add.wrappedValue = true }.disabled(!canAdd)
                    }
                }
        }
    }
}
