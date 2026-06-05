import SwiftUI

/// Add-or-edit sheet for a single reply template. Presented from ReplyTemplatePickerView.
/// On save, a new template always attaches to the current repo (owner/repo passed in);
/// editing updates the existing record in place.
struct ReplyTemplateEditorView: View {
    let store: ReplyTemplateStore
    let owner: String
    let repo: String
    /// nil → add mode; non-nil → edit that template.
    var existing: ReplyTemplate?

    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    // NOTE: must NOT be named `body` — that collides with View's `var body: some View`
    // and fails to compile with "invalid redeclaration of 'body'".
    @State private var messageBody: String

    init(store: ReplyTemplateStore, owner: String, repo: String, existing: ReplyTemplate? = nil) {
        self.store = store
        self.owner = owner
        self.repo = repo
        self.existing = existing
        _title = State(initialValue: existing?.title ?? "")
        _messageBody = State(initialValue: existing?.body ?? "")
    }

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty
            && !messageBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Title") {
                    TextField("e.g. Thanks for the report", text: $title)
                }
                Section("Message") {
                    TextEditor(text: $messageBody)
                        .font(.body)
                        .frame(minHeight: 160)
                }
            }
            .navigationTitle(existing == nil ? "New Template" : "Edit Template")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .fontWeight(.semibold)
                        .disabled(!canSave)
                }
            }
        }
        .frame(minWidth: 380, minHeight: 320)
    }

    private func save() {
        let trimmedTitle = title.trimmingCharacters(in: .whitespaces)
        let trimmedBody = messageBody.trimmingCharacters(in: .whitespacesAndNewlines)
        if let existing {
            store.update(existing, title: trimmedTitle, body: trimmedBody)
        } else {
            store.create(owner: owner, repo: repo, title: trimmedTitle, body: trimmedBody)
        }
        dismiss()
    }
}
