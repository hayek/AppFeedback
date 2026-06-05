import SwiftUI

/// Modal that lists prewritten reply templates for single selection, with a this-repo /
/// global scope toggle, full add/edit/delete, and two CTAs: Send (immediate) and Prefill.
/// The host provides onSend/onPrefill, which build the ComposeRequest for its reply context.
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
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $scope) {
                    Text("\(repoOwner)/\(repoName)").tag(Scope.thisRepo)
                    Text("Global").tag(Scope.global)
                }
                .pickerStyle(.segmented)
                .padding(8)

                Divider()

                list

                Divider()
                footer
            }
            .navigationTitle("Reply Templates")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showAdd) {
                ReplyTemplateEditorView(store: store, owner: repoOwner, repo: repoName, existing: nil)
            }
            .sheet(item: $editingTemplate) { tmpl in
                ReplyTemplateEditorView(store: store, owner: repoOwner, repo: repoName, existing: tmpl)
            }
        }
        .frame(minWidth: 420, minHeight: 420)
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
        HStack {
            PanelAddButton(title: "Add") { showAdd = true }
                .fixedSize()
            Spacer()
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
