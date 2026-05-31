import SwiftUI

struct ReleaseRecipientsSheet: View {
    let repo: RepoConfig
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

    var body: some View {
        NavigationStack {
            Form {
                Section("What's new") {
                    TextField("Subject", text: $template.subject)
                    TextField("Body", text: $template.body, axis: .vertical).lineLimit(6...18)
                    Text("Placeholders: {appName} {version} {whatsNew} {theirFeedbacks}")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Section {
                    HStack {
                        Button("Select all") { selected = Set(recipients.map(\.email)) }
                        Button("Deselect all") { selected = [] }
                    }
                    ForEach(recipients) { r in
                        Toggle(isOn: Binding(
                            get: { selected.contains(r.email) },
                            set: { on in if on { selected.insert(r.email) } else { selected.remove(r.email) } }
                        )) {
                            VStack(alignment: .leading) {
                                Text(r.email)
                                Text(r.feedbackNumbers.map { "#\($0)" }.joined(separator: " "))
                                    .font(.caption2).foregroundStyle(.secondary)
                                if alreadySent.contains(r.email) {
                                    Text("Already emailed").font(.caption2).foregroundStyle(.orange)
                                }
                            }
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
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send & Release") { run() }.disabled(sending)
                }
            }
            .onAppear {
                template = .default(appName: appName, version: version.name, whatsNew: version.changelog)
                selected = Set(recipients.map(\.email)).subtracting(alreadySent)   // pre-check all except already-sent
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
