import SwiftUI

struct NewVersionSheet: View {
    let repo: RepoConfig
    var versionStore: VersionStore
    var onCreated: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var changelog = ""
    @State private var working = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Version") { TextField("Name (e.g. 1.2.0)", text: $name) }
                Section("What's new") { TextField("Changelog", text: $changelog, axis: .vertical).lineLimit(4...12) }
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            }
            #if os(macOS)
            .formStyle(.grouped)
            #endif
            .navigationTitle("New Version")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { create() }.disabled(name.isEmpty || working)
                }
            }
        }
    }

    private func create() {
        working = true; errorMessage = nil
        let version = versionStore.create(repoOwner: repo.owner, repoName: repo.repo, name: name, changelog: changelog)
        let service = VersionService(store: versionStore)
        Task {
            do { try await service.provisionMilestone(repo: repo, version: version); onCreated(); dismiss() }
            catch {
                versionStore.delete(version)   // roll back local row if milestone creation failed
                errorMessage = error.localizedDescription; working = false
            }
        }
    }
}
