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
    var senderAccountID: UUID? = nil

    @Environment(MailAccountStore.self) private var store
    @Environment(MailSettingsStore.self) private var settingsStore
    @Environment(MailThreadStore.self) private var threadStore
    @Environment(OutboundSendTracker.self) private var outboundTracker
    @Environment(OutboundFailureStore.self) private var outboundFailures
    @Environment(ActivityLog.self) private var activityLog
    @Environment(SettingsNavigation.self) private var settingsNavigation
    @Environment(MailToGitHubMirrorHolder.self) private var mirrorHolder: MailToGitHubMirrorHolder?
    @Environment(\.dismiss) private var dismiss
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif

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
                ComposeFormCore(
                    vm: vm,
                    headerPreview: headerPreview,
                    footerPreview: footerPreview,
                    sendLabel: "Send",
                    onSend: {
                        Task { await vm.send() }
                        dismiss()
                    },
                    onDiscard: { dismiss() },
                    discardLabel: "Cancel"
                )
            }
        }
        .onAppear { refreshPreviews(vm: vm) }
        .onChange(of: settingsStore.settings.templateHeaderHTML) { _, _ in refreshPreviews(vm: vm) }
        .onChange(of: settingsStore.settings.templateFooterHTML) { _, _ in refreshPreviews(vm: vm) }
    }

    private var hasCredentials: Bool {
        guard let id = senderAccountID ?? store.defaultSender?.id,
              let acc = store.account(id: id) else { return false }
        return !acc.smtpUsername.isEmpty
    }

    private var currentTemplate: MailTemplate {
        MailTemplate(
            headerHTML: settingsStore.settings.templateHeaderHTML,
            footerHTML: settingsStore.settings.templateFooterHTML
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
            Button("Open Settings…") {
                openWindow(id: "settings")
            }
            #endif
        }
        .padding(8)
        .background(Color.yellow.opacity(0.18))
    }

    private func setupViewModel() {
        viewModel = ComposeMailViewModel(
            recipient: recipient,
            issue: issue,
            repoOwner: repoOwner,
            repoName: repoName,
            store: store,
            settingsStore: settingsStore,
            threadStore: threadStore,
            tracker: outboundTracker,
            failureStore: outboundFailures,
            sender: MailSender(),
            activityLog: activityLog,
            mirror: mirrorHolder?.mirror,
            inReplyTo: inReplyTo,
            initialSubject: subjectOverride,
            senderAccountID: senderAccountID ?? store.defaultSender?.id ?? UUID()
        )
    }
}

extension ComposeMailView {
    init(request: ComposeRequest) {
        self.init(
            recipient: request.recipient,
            issue: request.issue,
            repoOwner: request.repoOwner,
            repoName: request.repoName,
            inReplyTo: request.inReplyTo,
            subjectOverride: request.subjectOverride,
            senderAccountID: request.senderAccountID
        )
    }
}

#endif
