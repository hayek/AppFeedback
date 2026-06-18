import SwiftUI

struct ReleaseRecipientsSheet: View {
    let repo: ProductConfig
    @Bindable var version: ProjectVersion
    let recipients: [ReleaseRecipient]
    let alreadySent: Set<String>
    let appName: String
    var makeService: () -> ReleaseNotificationService
    var feedback: [FeedbackIssue]
    var onPublish: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<String> = []
    @State private var template: ReleaseEmailTemplate = .init(subject: "", body: "")
    @State private var progress: (Int, Int)? = nil
    @State private var sending = false
    @State private var previewRecipient: ReleaseRecipient?

    private var feedbackTitles: [Int: String] {
        Dictionary(feedback.map { ($0.number, $0.title) }, uniquingKeysWith: { a, _ in a })
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("What's new") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Subject").font(.caption).foregroundStyle(.secondary)
                        TextField("Subject", text: $template.subject)
                            .labelsHidden()
                            .multilineTextAlignment(.leading)
                            .textFieldStyle(.roundedBorder)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Body").font(.caption).foregroundStyle(.secondary)
                        // TextEditor (not a vertical TextField) so Return inserts a newline
                        // instead of committing the edit on macOS.
                        TextEditor(text: $template.body)
                            .textEditorStyle(.plain)
                            .scrollContentBackground(.hidden)
                            .font(.body)
                            .frame(minHeight: 160)
                            .padding(6)
                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.04)))
                            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
                    }
                    Text("Placeholders: {appName} {version} {whatsNew} {theirFeedbacks}")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Section {
                    HStack {
                        Button("Select all") { selected = Set(recipients.map(\.email)) }
                        Button("Deselect all") { selected = [] }
                    }
                    ForEach(recipients) { r in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(r.email)
                                ForEach(r.feedbackNumbers, id: \.self) { n in
                                    Text(feedbackTitles[n].map { "#\(n)  \($0)" } ?? "#\(n)")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                                if alreadySent.contains(r.email) {
                                    Text("Already emailed").font(.caption2).foregroundStyle(.orange)
                                }
                            }
                            Spacer(minLength: 8)
                            Button { previewRecipient = r } label: {
                                Label("Preview", systemImage: "eye").font(.caption)
                            }
                            .buttonStyle(.borderless)
                            Toggle("", isOn: Binding(
                                get: { selected.contains(r.email) },
                                set: { on in if on { selected.insert(r.email) } else { selected.remove(r.email) } }
                            ))
                            .labelsHidden()
                        }
                    }
                } header: { Text("Recipients (\(selected.count) selected)") }
                if let progress { Section { ProgressView(value: Double(progress.0), total: Double(max(progress.1, 1))) {
                    Text("Sending \(progress.0)/\(progress.1)") } } }
            }
            #if os(macOS)
            .formStyle(.grouped)
            #endif
            .navigationTitle("Release \(version.name)")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(sending) }
                // .primaryAction (not .confirmationAction) so Return is NOT bound to send —
                // otherwise pressing Return in the multi-line Body editor would send & release
                // instead of inserting a newline. Send is click-only.
                ToolbarItem(placement: .primaryAction) {
                    Button("Send & Release") { run() }
                        .buttonStyle(.borderedProminent)
                        .fontWeight(.semibold)
                        .disabled(sending)
                }
            }
            .onAppear {
                template = .default(appName: appName, version: version.name, whatsNew: version.changelog)
                selected = Set(recipients.map(\.email)).subtracting(alreadySent)   // pre-check all except already-sent
            }
            .sheet(item: $previewRecipient) { r in
                ReleaseMessagePreview(
                    recipientEmail: r.email,
                    rendered: template.render(appName: appName, version: version.name,
                                              whatsNew: version.changelog, feedbackNumbers: r.feedbackNumbers))
            }
        }
    }

    private func run() {
        sending = true
        let chosen = recipients.filter { selected.contains($0.email) }
        let service = makeService()
        Task {
            await service.send(repo: repo, version: version, recipients: chosen, feedback: feedback,
                template: template, appName: appName, onProgress: { progress = ($0, $1) })
            await onPublish()
            sending = false
            dismiss()
        }
    }
}

/// Shows the subject/body exactly as one recipient will receive it — placeholders filled
/// with that recipient's feedback numbers, matching `ReleaseNotificationService.send`.
private struct ReleaseMessagePreview: View {
    let recipientEmail: String
    let rendered: ReleaseEmailTemplate.Rendered
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    field("To", value: recipientEmail, mono: true)
                    field("Subject", value: rendered.subject)
                    field("Body", value: rendered.body)
                }
                .padding(20)
            }
            .navigationTitle("Preview")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 380)
        #endif
    }

    @ViewBuilder private func field(_ label: String, value: String, mono: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value.isEmpty ? "—" : value)
                .font(mono ? .body.monospaced() : .body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(11)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
        }
    }
}
