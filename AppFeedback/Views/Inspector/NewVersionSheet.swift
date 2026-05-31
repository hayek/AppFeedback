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
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Image(systemName: "number")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.tertiary)
                            TextField("1.2.0", text: $name)
                                .textFieldStyle(.plain)
                                .font(.title2.weight(.semibold))
                        }
                        Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
                    }

                    field("What's new") {
                        TextField("What changed in this version…", text: $changelog, axis: .vertical)
                            .textFieldStyle(.plain)
                            .font(.body)
                            .lineLimit(5...14)
                            .padding(11)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.045)))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.06), lineWidth: 1))
                    }

                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote).foregroundStyle(.red)
                    }
                }
                .padding(20)
            }
            .navigationTitle("New Version")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { create() }
                        .fontWeight(.semibold)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || working)
                }
            }
        }
        #if os(macOS)
        .frame(width: 440, height: 480)
        #endif
    }

    @ViewBuilder
    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(label.uppercased())
                .font(.caption2.weight(.semibold))
                .tracking(1.0)
                .foregroundStyle(.secondary)
            content()
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
