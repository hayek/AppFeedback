import SwiftUI

struct NewVersionSheet: View {
    /// Hands the entered values back so the caller can create the version optimistically and
    /// provision the GitHub milestone in the background (mirrors `CreateTaskSheet.onSubmit`).
    var onSubmit: (VersionDraft) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var title = ""
    @State private var changelog = ""
    /// Guards a fast double-tap of Create from submitting the same version twice.
    @State private var submitted = false

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

                    field("Release title") {
                        TextField("e.g. Performance & polish", text: $title)
                            .textFieldStyle(.plain)
                            .font(.body)
                            .padding(11)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.045)))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.06), lineWidth: 1))
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
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || submitted)
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
        guard !submitted else { return }
        submitted = true
        onSubmit(VersionDraft(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            releaseTitle: title,
            changelog: changelog))
        dismiss()
    }
}
