#if os(macOS) && canImport(SwiftMail)
import SwiftUI
import AppKit

struct ComposeMailView: View {
    let recipient: String
    let issue: FeedbackIssue
    let repoOwner: String
    let repoName: String

    @Environment(MailSettings.self) private var settings
    @Environment(ActivityLog.self) private var activityLog
    @Environment(\.dismiss) private var dismiss

    @State private var viewModel: ComposeMailViewModel?

    var body: some View {
        Group {
            if let vm = viewModel {
                composeForm(vm: vm)
            } else {
                ProgressView().task { setupViewModel() }
            }
        }
        .frame(minWidth: 540, minHeight: 460)
    }

    @ViewBuilder
    private func composeForm(vm: ComposeMailViewModel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if settings.credentials == nil {
                missingCredentialsBanner
            }
            recipientRow
            Divider()
            subjectRow(vm: vm)
            Divider()
            RichTextToolbar()
            RichTextEditor(attributedText: bindingFor(vm), minHeight: 240)
                .frame(minHeight: 240)
            Divider()
            footerButtons(vm: vm)
        }
    }

    private var missingCredentialsBanner: some View {
        HStack {
            Image(systemName: "envelope.badge")
            Text("Configure email in Settings → Email to send from this app.")
            Spacer()
            Button("Open Settings…") {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
        }
        .padding(8)
        .background(Color.yellow.opacity(0.18))
    }

    private var recipientRow: some View {
        HStack {
            Text("To:").foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
            Text(recipient).fontWeight(.medium)
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func subjectRow(vm: ComposeMailViewModel) -> some View {
        HStack {
            Text("Subject:").foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
            TextField("", text: Binding(
                get: { vm.subject },
                set: { vm.subject = $0 }
            ))
            .textFieldStyle(.plain)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func footerButtons(vm: ComposeMailViewModel) -> some View {
        HStack {
            Spacer()
            Button("Cancel") { dismiss() }
            Button("Send") {
                Task { await vm.send() }
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!vm.canSend)
        }
        .padding(12)
    }

    private func bindingFor(_ vm: ComposeMailViewModel) -> Binding<NSAttributedString> {
        Binding(get: { vm.body }, set: { vm.body = $0 })
    }

    private func setupViewModel() {
        viewModel = ComposeMailViewModel(
            recipient: recipient,
            issue: issue,
            repoOwner: repoOwner,
            repoName: repoName,
            settings: settings,
            sender: MailSender(),
            activityLog: activityLog
        )
    }
}
#endif
