import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct MailThreadView: View {
    let thread: MailThread
    let issue: FeedbackIssue
    let repoOwner: String
    let repoName: String
    let appColor: Color

    @Environment(MailAccountStore.self) private var accountStore
    @Environment(MailDraftStore.self) private var drafts

    @State private var isExpanded: Bool = true

    private var replyKey: DraftKey { .reply(threadID: thread.id) }

    private var activeReply: ComposeRequest? { drafts.openRequest(for: replyKey) }
    @Environment(ReplyTemplateStore.self) private var replyTemplateStore
    @State private var showTemplatePicker: Bool = false

    private var messages: [MailMessage] { thread.sortedDedupedMessages }

    private var resolvedSenderAccountID: UUID? {
        messages.last?.replySenderAccountID(in: accountStore) ?? accountStore.defaultSender?.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isExpanded {
                Divider()
                ForEach(messages) { message in
                    MailMessageRowView(message: message, issue: issue,
                                       repoOwner: repoOwner, repoName: repoName)
                    Divider()
                }
                replyArea
            }
        }
    }

    private var headerPrefix: String {
        let count = thread.messages?.count ?? 0
        let suffix = count == 1 ? "message" : "messages"
        return "\(count) \(suffix) — last reply"
    }

    private var header: some View {
        HStack(spacing: 6) {
            Button(action: { withAnimation { isExpanded.toggle() } }) {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .foregroundStyle(.secondary)
                    Text(headerPrefix)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            ToggleableDateText(date: thread.lastMessageAt)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Spacer()
        }
        .padding(.vertical, 4)
    }

    private var replyRecipient: String? { messages.last?.replyRecipient }

    private func beginReply(senderAccountID: UUID? = nil) {
        #if canImport(SwiftMail)
        guard let last = messages.last, let recipient = replyRecipient else { return }
        guard let chosen = senderAccountID ?? resolvedSenderAccountID else { return }
        let headers = MailMessageHeaders(
            messageID: last.messageID,
            inReplyTo: last.inReplyTo,
            references: last.referencesAsArray
        )
        let request = ComposeRequest(
            recipient: recipient,
            issue: issue,
            repoOwner: repoOwner,
            repoName: repoName,
            inReplyTo: headers,
            subjectOverride: MailSubject.replyPrefixed(last.subject),
            senderAccountID: chosen
        )
        withAnimation(.easeOut(duration: 0.2)) {
            drafts.setOpenRequest(request, for: replyKey)
        }
        #endif
    }

    private func useTemplate(_ template: ReplyTemplate, autoSend: Bool) {
        #if canImport(SwiftMail)
        guard let last = messages.last, let recipient = replyRecipient else { return }
        guard let chosen = resolvedSenderAccountID else { return }
        let headers = MailMessageHeaders(
            messageID: last.messageID,
            inReplyTo: last.inReplyTo,
            references: last.referencesAsArray
        )
        let request = ComposeRequest(
            recipient: recipient,
            issue: issue,
            repoOwner: repoOwner,
            repoName: repoName,
            inReplyTo: headers,
            subjectOverride: MailSubject.replyPrefixed(last.subject),
            senderAccountID: chosen,
            initialBody: template.body,
            autoSend: autoSend
        )
        withAnimation(.easeOut(duration: 0.2)) {
            drafts.setOpenRequest(request, for: replyKey)
        }
        #endif
    }

    private func copyRecipient() {
        guard let recipient = replyRecipient else { return }
        #if os(macOS)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(recipient, forType: .string)
        #else
        UIPasteboard.general.string = recipient
        #endif
    }

    @ViewBuilder
    private var replyArea: some View {
        if let req = activeReply {
            #if canImport(SwiftMail)
            InlineReplyView(
                key: replyKey,
                request: req,
                onClose: {
                    withAnimation(.easeOut(duration: 0.2)) {
                        drafts.clearOpenRequest(for: replyKey)
                    }
                }
            )
            .padding(.top, 8)
            #endif
        } else if let recipient = replyRecipient {
            let options = accountStore.accounts
                .filter { !$0.smtpUsername.isEmpty }
                .map { ReplyBadgeButton.ReplyFromOption(id: $0.id, address: $0.smtpUsername) }
            ReplyBadgeButton(
                email: recipient,
                color: appColor,
                onReply: { beginReply() },
                onCopy: copyRecipient,
                replyFromOptions: options.count > 1 ? options : [],
                onReplyFrom: { id in beginReply(senderAccountID: id) },
                onTemplates: { showTemplatePicker = true }
            )
            .padding(.top, 8)
            .frame(maxWidth: .infinity, alignment: .trailing)
            #if canImport(SwiftMail)
            .sheet(isPresented: $showTemplatePicker) {
                ReplyTemplatePickerView(
                    store: replyTemplateStore,
                    repoOwner: repoOwner,
                    repoName: repoName,
                    accent: appColor,
                    onSend: { template in useTemplate(template, autoSend: true) },
                    onPrefill: { template in useTemplate(template, autoSend: false) }
                )
            }
            #endif
        }
    }
}


