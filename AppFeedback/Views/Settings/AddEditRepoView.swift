import SwiftUI

struct AddEditRepoView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: RepoStore

    var existing: RepoConfig?

    @State private var displayName = ""
    @State private var owner = ""
    @State private var repo = ""
    @State private var token = ""

    private var isEditing: Bool { existing != nil }

    private var isValid: Bool {
        !displayName.trimmingCharacters(in: .whitespaces).isEmpty
        && !owner.trimmingCharacters(in: .whitespaces).isEmpty
        && !repo.trimmingCharacters(in: .whitespaces).isEmpty
        && !token.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(spacing: 20) {
                    fieldSection(
                        label: "Display Name",
                        hint: "A friendly name shown in the sidebar"
                    ) {
                        StyledTextField("My App Feedback", text: $displayName)
                    }

                    fieldSection(
                        label: "GitHub Repository",
                        hint: "The owner and repository name on GitHub"
                    ) {
                        HStack(spacing: 8) {
                            StyledTextField("owner", text: $owner, monospaced: true)
                                .autocorrectionDisabled()
                                #if os(iOS)
                                .textInputAutocapitalization(.never)
                                #endif
                            Text("/")
                                .foregroundStyle(.tertiary)
                                .font(.system(size: 14, weight: .light))
                            StyledTextField("repo-name", text: $repo, monospaced: true)
                                .autocorrectionDisabled()
                                #if os(iOS)
                                .textInputAutocapitalization(.never)
                                #endif
                        }
                    }

                    fieldSection(
                        label: "GitHub Token",
                        hint: nil
                    ) {
                        StyledTextField("ghp_…", text: $token, secure: true, monospaced: true)
                            .autocorrectionDisabled()
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
                }
                .padding(20)
            }
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 320)
        #endif
        .onAppear { populateFromExisting() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text(isEditing ? "Edit Repository" : "Add Repository")
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

                Button(isEditing ? "Save" : "Add") { save() }
                    .disabled(!isValid)
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

    // MARK: - Logic

    private func populateFromExisting() {
        guard let existing else { return }
        displayName = existing.displayName
        owner = existing.owner
        repo = existing.repo
        token = KeychainService.load(for: existing) ?? ""
    }

    private func save() {
        let trimName = displayName.trimmingCharacters(in: .whitespaces)
        let trimOwner = owner.trimmingCharacters(in: .whitespaces)
        let trimRepo = repo.trimmingCharacters(in: .whitespaces)
        let trimToken = token.trimmingCharacters(in: .whitespaces)

        if let existing {
            var updated = existing
            updated.displayName = trimName
            updated.owner = trimOwner
            updated.repo = trimRepo
            store.update(updated)
            KeychainService.save(token: trimToken, for: updated)
        } else {
            let newRepo = RepoConfig(displayName: trimName, owner: trimOwner, repo: trimRepo)
            store.add(newRepo)
            KeychainService.save(token: trimToken, for: newRepo)
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
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
        )
    }
}
