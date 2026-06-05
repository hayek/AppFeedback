import SwiftUI

/// Modal that lists prewritten reply templates for single selection. A scope dropdown
/// (top-right) switches between this-repo and a merged "Global" view; the footer offers
/// Add, plus the Send / Prefill CTAs. The host provides onSend/onPrefill, which build the
/// ComposeRequest for its reply context.
struct ReplyTemplatePickerView: View {
    let store: ReplyTemplateStore
    let repoOwner: String
    let repoName: String
    var accent: Color = .accentColor
    let onSend: (ReplyTemplate) -> Void
    let onPrefill: (ReplyTemplate) -> Void

    @Environment(\.dismiss) private var dismiss

    private enum Scope: Hashable { case thisRepo, global }

    @State private var scope: Scope = .thisRepo
    @State private var selection: UUID?
    @State private var showAdd = false
    @State private var editingTemplate: ReplyTemplate?

    private var items: [ReplyTemplate] {
        scope == .thisRepo ? store.templates(owner: repoOwner, repo: repoName) : store.allTemplates()
    }

    private var selectedTemplate: ReplyTemplate? {
        guard let selection else { return nil }
        return items.first { $0.id == selection }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            list
            Divider()
            footer
        }
        // A fixed min size suits a free-floating macOS sheet, but on iPhone the sheet fills the
        // screen width — forcing it wider than the device overflows and clips both edges.
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 440)
        #endif
        .sheet(isPresented: $showAdd) {
            ReplyTemplateEditorView(store: store, owner: repoOwner, repo: repoName, existing: nil)
        }
        .sheet(item: $editingTemplate) { tmpl in
            ReplyTemplateEditorView(store: store, owner: repoOwner, repo: repoName, existing: tmpl)
        }
    }

    private var header: some View {
        HStack {
            Text("Reply Templates")
                .font(.headline)
            Spacer()
            Picker("Scope", selection: $scope) {
                Text("\(repoOwner)/\(repoName)").tag(Scope.thisRepo)
                Text("Global").tag(Scope.global)
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var list: some View {
        if items.isEmpty {
            ContentUnavailableView {
                Label("No Templates", systemImage: "list.bullet.rectangle")
            } description: {
                Text(scope == .thisRepo
                     ? "Add a reply template for \(repoOwner)/\(repoName)."
                     : "No templates in any repo yet.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(selection: $selection) {
                ForEach(items) { template in
                    row(template).tag(template.id)
                }
            }
            .tint(accent)
        }
    }

    private func row(_ template: ReplyTemplate) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(template.title).font(.body.weight(.medium))
                Spacer()
                if scope == .global {
                    Text("\(template.repoOwner)/\(template.repoName)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Text(template.body)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("Edit…") { editingTemplate = template }
            Button("Delete", role: .destructive) {
                if selection == template.id { selection = nil }
                store.delete(template)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                showAdd = true
            } label: {
                Label("Add", systemImage: "plus")
            }
            .buttonStyle(.bordered)

            Spacer()

            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)

            Button("Prefill…") {
                if let t = selectedTemplate { onPrefill(t); dismiss() }
            }
            .buttonStyle(.bordered)
            .disabled(selectedTemplate == nil)

            Button("Send") {
                if let t = selectedTemplate { onSend(t); dismiss() }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(selectedTemplate == nil)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
