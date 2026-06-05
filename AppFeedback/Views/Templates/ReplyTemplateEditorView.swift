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
    @FocusState private var titleFocused: Bool

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
        VStack(alignment: .leading, spacing: 0) {
            Text(existing == nil ? "New Template" : "Edit Template")
                .font(.headline)
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 16)

            VStack(alignment: .leading, spacing: 16) {
                field(label: "Title") {
                    TextField("e.g. Thanks for the report", text: $title)
                        .textFieldStyle(.roundedBorder)
                        .focused($titleFocused)
                }
                field(label: "Message") {
                    TextEditor(text: $messageBody)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .frame(minHeight: 180)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.25)))
                }
            }
            .padding(.horizontal, 20)

            Spacer(minLength: 24)
            Divider()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .frame(minWidth: 440, minHeight: 400)
        .onAppear { titleFocused = true }
    }

    /// A left-aligned field label stacked above its input.
    private func field<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            content()
        }
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
