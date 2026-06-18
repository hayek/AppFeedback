import SwiftUI

struct CreateTaskSheet: View {
    let repo: ProductConfig
    let versions: [ProjectVersion]
    /// Hands the entered values back so the caller can show the task optimistically and drive
    /// the GitHub write after this sheet dismisses (mirrors how a mail reply sends in the
    /// background after the composer closes).
    var onSubmit: (TaskDraft) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var prose = ""
    @State private var status: TaskStatus = .todo
    @State private var priority: TaskPriority = .med
    @State private var selectedVersionID: UUID?
    /// Guards against a fast double-tap of Create submitting the same draft (and thus creating the
    /// same issue) twice before the sheet finishes dismissing.
    @State private var submitted = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Hero title field
                    VStack(alignment: .leading, spacing: 6) {
                        TextField("Task title", text: $title)
                            .textFieldStyle(.plain)
                            .font(.title2.weight(.semibold))
                        Rectangle()
                            .fill(Color.primary.opacity(0.08))
                            .frame(height: 1)
                    }

                    field("Notes") {
                        TextField("Add details…", text: $prose, axis: .vertical)
                            .textFieldStyle(.plain)
                            .font(.body)
                            .lineLimit(3...8)
                            .padding(11)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color.primary.opacity(0.045))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
                            )
                    }

                    field("Status") {
                        HStack(spacing: 8) {
                            ForEach(TaskStatus.allCases, id: \.self) { s in
                                SelectChip(title: s.displayName, tint: s.accent, selected: status == s) { status = s }
                            }
                        }
                    }

                    field("Priority") {
                        HStack(spacing: 8) {
                            ForEach(TaskPriority.allCases, id: \.self) { p in
                                SelectChip(title: p.displayName, tint: p.accent, selected: priority == p) { priority = p }
                            }
                        }
                    }

                    field("Version") {
                        Menu {
                            Button("None") { selectedVersionID = nil }
                            ForEach(versions) { v in Button(v.name) { selectedVersionID = v.id } }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "shippingbox")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                Text(versions.first { $0.id == selectedVersionID }?.name ?? "None")
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.primary)
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color.primary.opacity(0.045))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
                            )
                            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .menuIndicator(.hidden)
                    }

                }
                .padding(20)
            }
            .navigationTitle("New Task")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { create() }
                        .fontWeight(.semibold)
                        .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        #if os(macOS)
        .frame(width: 440, height: 560)
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
        let version = versions.first { $0.id == selectedVersionID }
        let draft = TaskDraft(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            prose: prose,
            status: status,
            priority: priority,
            milestoneNumber: version?.milestoneNumber,
            milestoneTitle: version?.name
        )
        onSubmit(draft)   // caller inserts the optimistic card and drives the GitHub write
        dismiss()
    }
}
