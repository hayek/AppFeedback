#if canImport(SwiftMail)
import SwiftUI
import AppFeedbackCore

/// In-place compose surface used by MailThreadView (replies) and IssueCardView (first-time
/// emails). Hydrates subject/body from MailDraftStore on appear, persists edits back so
/// drafts survive thread collapse and LazyVStack recycling, and clears the draft on Send
/// or explicit Discard.
struct InlineReplyView: View {
    let key: DraftKey
    let request: ComposeRequest
    var onClose: () -> Void

    @Environment(MailAccountStore.self) private var store
    @Environment(MailSettingsStore.self) private var settingsStore
    @Environment(MailThreadStore.self) private var threadStore
    @Environment(OutboundSendTracker.self) private var outboundTracker
    @Environment(OutboundFailureStore.self) private var outboundFailures
    @Environment(ActivityLog.self) private var activityLog
    @Environment(MailToGitHubMirrorHolder.self) private var mirrorHolder: MailToGitHubMirrorHolder?
    @Environment(MailDraftStore.self) private var drafts
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif

    @State private var viewModel: ComposeMailViewModel?
    @State private var headerPreview: String = ""
    @State private var footerPreview: String = ""
    @State private var showsDiscardConfirm: Bool = false
    @FocusState private var bodyFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerStrip
            Divider()
            if let vm = viewModel {
                if !hasCredentials {
                    missingCredentialsBanner
                }
                ComposeFormCore(
                    vm: vm,
                    headerPreview: headerPreview,
                    footerPreview: footerPreview,
                    sendLabel: "Send",
                    onSend: { send(vm: vm) },
                    onDiscard: { attemptDiscard(vm: vm) },
                    discardLabel: "Discard",
                    bodyFocus: $bodyFocused
                )
                .onAppear {
                    refreshPreviews(vm: vm)
                    bodyFocused = true
                }
                .onChange(of: vm.subject) { _, newValue in
                    drafts.setSubject(newValue, for: key)
                }
                .onChange(of: vm.body) { _, newValue in
                    drafts.setBody(newValue.string, for: key)
                }
                .onChange(of: settingsStore.settings.templateHeaderHTML) { _, _ in refreshPreviews(vm: vm) }
                .onChange(of: settingsStore.settings.templateFooterHTML) { _, _ in refreshPreviews(vm: vm) }

            } else {
                ProgressView().padding(12).task { setupViewModel() }
            }
        }
        .background(.background.tertiary, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(.secondary.opacity(0.25), lineWidth: 1)
        )
        .padding(.top, 6)
        .alert("Discard draft?", isPresented: $showsDiscardConfirm) {
            Button("Discard", role: .destructive) {
                drafts.clear(key)
                onClose()
            }
            Button("Keep", role: .cancel) { }
        } message: {
            Text("This will discard the text you've typed.")
        }
    }

    // MARK: - Header strip

    private var headerStrip: some View {
        HStack(spacing: 8) {
            Image(systemName: request.inReplyTo == nil ? "envelope" : "arrowshape.turn.up.left")
                .foregroundStyle(.secondary)
            Text(headerTitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button {
                if let vm = viewModel { attemptDiscard(vm: vm) } else { onClose() }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close composer")
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
    }

    private var headerTitle: String {
        let verb = request.inReplyTo == nil ? "New email to" : "Reply to"
        return "\(verb) \(request.recipient)"
    }

    private var hasCredentials: Bool {
        guard let id = request.senderAccountID ?? store.defaultSender?.id,
              let acc = store.account(id: id) else { return false }
        return !acc.smtpUsername.isEmpty
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

    private func attemptDiscard(vm: ComposeMailViewModel) {
        if vm.body.length > 0 {
            showsDiscardConfirm = true
        } else {
            drafts.clear(key)
            onClose()
        }
    }

    private func send(vm: ComposeMailViewModel) {
        // Dismiss the composer immediately on Send. vm.send() records the outbound
        // message (shown in the thread with a "sending…" badge) and tracks success/
        // failure in the thread store + tracker, so the SMTP round-trip can finish in
        // the background after this view is gone. The Task retains vm until it returns.
        drafts.clear(key)
        onClose()
        Task { await vm.send() }
    }

    private func setupViewModel() {
        let senderID = request.senderAccountID ?? store.defaultSender?.id ?? UUID()
        // Lazily build an IMAP client for the sender account so the VM can save a copy of the sent
        // reply to the Sent folder (for providers that don't auto-file SMTP sends). The provider is
        // an actor (Sendable), so it's safe to capture in the @Sendable closure.
        let appenderProvider = IMAPClientProvider(accountStore: store, accountID: senderID)
        let vm = ComposeMailViewModel(
            recipient: request.recipient,
            issue: request.issue,
            repoOwner: request.repoOwner,
            repoName: request.repoName,
            store: store,
            settingsStore: settingsStore,
            threadStore: threadStore,
            tracker: outboundTracker,
            failureStore: outboundFailures,
            sender: MailSender(),
            activityLog: activityLog,
            mirror: mirrorHolder?.mirror,
            inReplyTo: request.inReplyTo,
            initialSubject: request.subjectOverride,
            senderAccountID: senderID,
            sentAppender: { @Sendable email in try await appenderProvider.appendToSent(email) }
        )

        if let existing = drafts.draft(for: key) {
            if !existing.subject.isEmpty { vm.subject = existing.subject }
            if !existing.body.isEmpty { vm.body = NSAttributedString(string: existing.body) }
        }

        // Template replies: seed the chosen template body, running it through the same
        // {{placeholder}} substitution that header/footer get. The body is USER_BODY only —
        // MailComposer.compose() still wraps it with HEADER + FOOTER, so a templated send
        // carries the same header/footer as a normal reply.
        if let initial = request.initialBody, !initial.isEmpty {
            let substituted = MailComposer().applyPlaceholders(initial, context: vm.placeholderContext())
            vm.body = NSAttributedString(string: substituted)
        }

        viewModel = vm

        // One-tap template send (the modal's primary CTA). Reuses the existing send path,
        // which dismisses the composer and finishes the SMTP round-trip in the background.
        // If there are no credentials, leave the composer open with the body seeded so it
        // gracefully degrades to a prefill the user can send manually.
        if request.autoSend, vm.body.length > 0, hasCredentials {
            send(vm: vm)
        }
    }

}

#endif
