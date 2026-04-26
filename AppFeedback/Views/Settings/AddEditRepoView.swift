import SwiftUI

struct AddEditRepoView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: RepoStore

    var existing: RepoConfig?

    @State private var displayName = ""
    @State private var owner = ""
    @State private var repo = ""
    @State private var token = ""

    private var isValid: Bool { !displayName.isEmpty && !owner.isEmpty && !repo.isEmpty && !token.isEmpty }
    private var title: String { existing == nil ? "Add Repo" : "Edit Repo" }

    var body: some View {
        Form {
            Section("Display Name") {
                TextField("My App Feedback", text: $displayName)
            }
            Section("GitHub Repository") {
                TextField("owner", text: $owner)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                TextField("repo-name", text: $repo)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
            }
            Section {
                SecureField("ghp_…", text: $token)
                    .autocorrectionDisabled()
            } header: {
                Text("GitHub Token")
            } footer: {
                Text("Requires repo read access. Stored in Keychain.")
                    .font(.caption)
            }
        }
        #if os(macOS)
        .formStyle(.grouped)
        .frame(width: 380)
        #endif
        .navigationTitle(title)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }.disabled(!isValid)
            }
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
        }
        .onAppear { populateFromExisting() }
    }

    private func populateFromExisting() {
        guard let existing else { return }
        displayName = existing.displayName
        owner = existing.owner
        repo = existing.repo
        token = KeychainService.load(for: existing) ?? ""
    }

    private func save() {
        if let existing {
            var updated = existing
            updated.displayName = displayName
            updated.owner = owner
            updated.repo = repo
            store.update(updated)
            KeychainService.save(token: token, for: updated)
        } else {
            let newRepo = RepoConfig(displayName: displayName, owner: owner, repo: repo)
            store.add(newRepo)
            KeychainService.save(token: token, for: newRepo)
        }
        dismiss()
    }
}
