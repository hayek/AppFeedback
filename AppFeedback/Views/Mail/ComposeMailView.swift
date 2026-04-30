#if canImport(SwiftMail)
import SwiftUI
#if os(macOS)
import AppKit
#endif

struct ComposeMailView: View {
    let recipient: String
    let issue: FeedbackIssue
    let repoOwner: String
    let repoName: String
    var inReplyTo: MailMessageHeaders? = nil
    var subjectOverride: String? = nil

    @Environment(MailAccountStore.self) private var store
    @Environment(MailThreadStore.self) private var threadStore
    @Environment(ActivityLog.self) private var activityLog
    @Environment(SettingsNavigation.self) private var settingsNavigation
    @Environment(MailToGitHubMirrorHolder.self) private var mirrorHolder: MailToGitHubMirrorHolder?
    @Environment(\.dismiss) private var dismiss

    @State private var viewModel: ComposeMailViewModel?
    @State private var headerPreview: String = ""
    @State private var footerPreview: String = ""

    var body: some View {
        Group {
            if let vm = viewModel {
                composeForm(vm: vm)
            } else {
                ProgressView().task { setupViewModel() }
            }
        }
        #if os(macOS)
        .frame(minWidth: 540, minHeight: 460)
        #endif
    }

    @ViewBuilder
    private func composeForm(vm: ComposeMailViewModel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            titleBar
            Divider()
            if !hasCredentials {
                missingCredentialsBanner
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    recipientRow
                    Divider()
                    subjectRow(vm: vm)
                    Divider()
                    templateRow(label: "Header", text: headerPreview)
                    Divider()
                    TextEditor(text: plainBindingFor(vm))
                        .font(.body)
                        .scrollDisabled(true)
                        .frame(minHeight: 200)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                    Divider()
                    templateRow(label: "Footer", text: footerPreview)
                }
            }
            Divider()
            footerButtons(vm: vm)
        }
        .onAppear { refreshPreviews(vm: vm) }
        .onChange(of: store.account?.templateHeaderHTML) { _, _ in refreshPreviews(vm: vm) }
        .onChange(of: store.account?.templateFooterHTML) { _, _ in refreshPreviews(vm: vm) }
    }

    private var hasCredentials: Bool {
        guard let acc = store.account else { return false }
        return !acc.smtpUsername.isEmpty
    }

    private var currentTemplate: MailTemplate {
        MailTemplate(
            headerHTML: store.account?.templateHeaderHTML ?? "",
            footerHTML: store.account?.templateFooterHTML ?? ""
        )
    }

    private func refreshPreviews(vm: ComposeMailViewModel) {
        let context = vm.placeholderContext()
        let composer = MailComposer()
        let template = currentTemplate
        headerPreview = MailTemplatePlainText
            .from(html: composer.applyPlaceholders(template.headerHTML, context: context))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        footerPreview = MailTemplatePlainText
            .from(html: composer.applyPlaceholders(template.footerHTML, context: context))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func templateRow(label: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(label):")
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .leading)
            Group {
                if text.isEmpty {
                    Text("Not set")
                        .foregroundStyle(.tertiary)
                        .italic()
                } else {
                    Text(text)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            #if os(macOS)
            SettingsLink {
                Label("Edit", systemImage: "pencil")
                    .labelStyle(.titleAndIcon)
            }
            .simultaneousGesture(TapGesture().onEnded {
                settingsNavigation.selectedTab = .email
            })
            .controlSize(.small)
            #endif
        }
        .font(.caption)
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var titleBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "envelope")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("New Email")
                    .font(.headline)
                Text("Re: \(issue.title)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var missingCredentialsBanner: some View {
        HStack {
            Image(systemName: "envelope.badge")
            Text("Configure email in Settings → Email to send from this app.")
            Spacer()
            #if os(macOS)
            SettingsLink {
                Text("Open Settings…")
            }
            #endif
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
            #if os(macOS)
            .keyboardShortcut(.return, modifiers: .command)
            #endif
            .disabled(!vm.canSend)
        }
        .padding(12)
    }

    private func plainBindingFor(_ vm: ComposeMailViewModel) -> Binding<String> {
        Binding(
            get: { vm.body.string },
            set: { vm.body = NSAttributedString(string: $0) }
        )
    }

    private func setupViewModel() {
        viewModel = ComposeMailViewModel(
            recipient: recipient,
            issue: issue,
            repoOwner: repoOwner,
            repoName: repoName,
            store: store,
            threadStore: threadStore,
            sender: MailSender(),
            activityLog: activityLog,
            mirror: mirrorHolder?.mirror,
            inReplyTo: inReplyTo,
            initialSubject: subjectOverride
        )
    }
}
#endif
