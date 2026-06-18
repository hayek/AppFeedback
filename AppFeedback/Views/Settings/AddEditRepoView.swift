import SwiftUI

struct AddEditRepoView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: ProductStore
    @Environment(GitHubAccountStore.self) private var accountStore

    var existing: ProductConfig?
    var embedInNavigation: Bool = true

    @State private var displayName = ""
    @State private var owner = ""
    @State private var repo = ""
    @State private var token = ""
    @State private var mirrorEmailsToGitHub = true
    @State private var redactEmailAddresses = true
    @State private var showGitHubLogin = false
    @State private var isSaving = false

    private var isEditing: Bool { existing != nil }

    private var isValid: Bool {
        !displayName.isEmpty && !owner.isEmpty && !repo.isEmpty && !token.isEmpty
    }

    private var existingRepoKeys: Set<String> {
        Set(store.repos.map { "\($0.owner)/\($0.repo)".lowercased() })
    }

    private var selectedRepoKey: String? {
        guard !owner.isEmpty, !repo.isEmpty else { return nil }
        return "\(owner)/\(repo)".lowercased()
    }

    var body: some View {
        platformContent
            .task { await populateFromExisting() }
            .sheet(isPresented: $showGitHubLogin) {
                GitHubLoginView(accountStore: accountStore)
            }
    }

    @ViewBuilder
    private var platformContent: some View {
        #if os(iOS)
        if embedInNavigation {
            NavigationStack {
                iosForm
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { dismiss() }
                        }
                    }
            }
        } else {
            iosForm
        }
        #else
        VStack(spacing: 0) {
            header
            Divider()
            formContent
        }
        .frame(minWidth: 440, minHeight: 320)
        #endif
    }

    #if os(iOS)
    private var iosForm: some View {
        formContent
            .navigationTitle(isEditing ? "Edit Product" : "Add Product")
            .navigationBarTitleDisplayMode(.inline)
    }
    #endif

    private var formContent: some View {
        ScrollView {
            VStack(spacing: 20) {
                if !isEditing {
                    if accountStore.accounts.isEmpty {
                        Button {
                            showGitHubLogin = true
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "person.badge.key.fill")
                                Text("Sign in with GitHub")
                                    .fontWeight(.semibold)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        AccountRepoPicker(
                            accounts: accountStore.accounts,
                            accountStore: accountStore,
                            existingRepoKeys: existingRepoKeys,
                            selectedKey: selectedRepoKey,
                            onSelect: { account, ghRepo in
                                owner = ghRepo.owner.login
                                repo = ghRepo.name
                                displayName = ghRepo.name
                                token = accountStore.token(for: account) ?? ""
                                redactEmailAddresses = !ghRepo.isPrivate
                            },
                            onConnectAnother: { showGitHubLogin = true }
                        )
                    }

                    HStack {
                        VStack { Divider() }
                        Text("or enter manually")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                        VStack { Divider() }
                    }
                }

                fieldSection(
                    label: "Display Name",
                    hint: "A friendly name shown in the sidebar"
                ) {
                    GroupBox {
                        StyledTextField("My App Feedback", text: $displayName)
                    }
                }

                fieldSection(
                    label: "GitHub Repository",
                    hint: "The owner and repository name on GitHub"
                ) {
                    GroupBox {
                        HStack(spacing: 0) {
                            StyledTextField("owner", text: $owner, monospaced: true)
                                .autocorrectionDisabled()
                                #if os(iOS)
                                .textInputAutocapitalization(.never)
                                #endif
                            Text("/")
                                .foregroundStyle(.tertiary)
                                .font(.system(size: 14, weight: .light))
                                .padding(.horizontal, 6)
                            StyledTextField("repo-name", text: $repo, monospaced: true)
                                .autocorrectionDisabled()
                                #if os(iOS)
                                .textInputAutocapitalization(.never)
                                #endif
                        }
                    }
                }

                fieldSection(
                    label: "Mirror to GitHub",
                    hint: "Posts every email reply as a comment on the issue"
                ) {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            Toggle(isOn: $mirrorEmailsToGitHub) {
                                Text("Cross-post emails to issue comments")
                                    .font(.system(size: 12))
                            }
                            .toggleStyle(.switch)

                            if mirrorEmailsToGitHub {
                                Divider()
                                Toggle(isOn: $redactEmailAddresses) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Redact sender email addresses")
                                            .font(.system(size: 12))
                                        Text(redactEmailAddresses
                                             ? "Shown as a***@example.com — recommended for public repos."
                                             : "Full addresses will appear in comment bodies.")
                                            .font(.system(size: 10))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .toggleStyle(.switch)
                            }
                        }
                        .padding(.horizontal, 4)
                        .padding(.vertical, 4)
                    }
                }

                fieldSection(
                    label: "GitHub Token",
                    hint: nil
                ) {
                    GroupBox {
                        StyledTextField("ghp_…", text: $token, secure: true, monospaced: true)
                            .autocorrectionDisabled()
                    }
                    HStack(spacing: 6) {
                        Image(systemName: "lock.shield")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Text("Requires repo read access. Stored securely in Keychain.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 4)
                }

                #if os(iOS)
                Button {
                    Task { await save() }
                } label: {
                    Text(isEditing ? "Save" : "Add Product")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isValid || isSaving)
                .padding(.top, 8)
                #endif
            }
            .padding(20)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(isEditing ? "Edit Product" : "Add Product")
                    .font(.system(size: 13, weight: .semibold))
                Text(isEditing ? "Update connection settings" : "Connect a GitHub repo to browse feedback")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 8) {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                Button(isEditing ? "Save" : "Add") { Task { await save() } }
                    .disabled(!isValid || isSaving)
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(isValid ? Color.accentColor : Color.accentColor.opacity(0.35),
                                in: RoundedRectangle(cornerRadius: 6))
                    .foregroundStyle(.white)
                    .animation(.easeOut(duration: 0.15), value: isValid)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.bar)
    }

    // MARK: - Field section helper

    @ViewBuilder
    private func fieldSection<Content: View>(
        label: String,
        hint: String?,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .kerning(0.5)
                if let hint {
                    Spacer()
                    Text(hint)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            content()
        }
    }

    private func populateFromExisting() async {
        guard let existing else { return }
        displayName = existing.displayName
        owner = existing.owner
        repo = existing.repo
        mirrorEmailsToGitHub = existing.mirrorEmailsToGitHub
        redactEmailAddresses = existing.redactEmailAddresses
        token = await KeychainService.load(for: existing) ?? ""
    }

    private func save() async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }

        let trimName = displayName.trimmingCharacters(in: .whitespaces)
        let trimOwner = owner.trimmingCharacters(in: .whitespaces)
        let trimRepo = repo.trimmingCharacters(in: .whitespaces)
        let trimToken = token.trimmingCharacters(in: .whitespaces)

        // Write the keychain entry BEFORE inserting/updating the store, so any view
        // that observes `repos` and refreshes tokens (e.g. SettingsView) sees the
        // token on its first read.
        if let existing {
            var updated = existing
            updated.displayName = trimName
            updated.owner = trimOwner
            updated.repo = trimRepo
            updated.mirrorEmailsToGitHub = mirrorEmailsToGitHub
            updated.redactEmailAddresses = redactEmailAddresses
            await KeychainService.save(token: trimToken, for: updated)
            store.update(updated)
        } else {
            let newRepo = ProductConfig(
                displayName: trimName,
                owner: trimOwner,
                repo: trimRepo,
                mirrorEmailsToGitHub: mirrorEmailsToGitHub,
                redactEmailAddresses: redactEmailAddresses
            )
            await KeychainService.save(token: trimToken, for: newRepo)
            store.add(newRepo)
        }
        dismiss()
    }
}

// MARK: - Styled text field

private struct StyledTextField: View {
    let placeholder: String
    @Binding var text: String
    var secure: Bool = false
    var monospaced: Bool = false

    init(_ placeholder: String, text: Binding<String>, secure: Bool = false, monospaced: Bool = false) {
        self.placeholder = placeholder
        self._text = text
        self.secure = secure
        self.monospaced = monospaced
    }

    var body: some View {
        Group {
            if secure {
                SecureField(placeholder, text: $text)
            } else {
                TextField(placeholder, text: $text)
            }
        }
        .font(monospaced ? .system(size: 12).monospaced() : .system(size: 12))
        .textFieldStyle(.plain)
        .padding(.horizontal, 4)
    }
}
