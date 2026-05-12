import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct ReplyTarget: Identifiable {
    let id = UUID()
    let recipient: String
    let subject: String
    let headers: MailMessageHeaders
}

struct MailThreadView: View {
    let thread: MailThread
    let issue: FeedbackIssue
    let repoOwner: String
    let repoName: String
    let appColor: Color

    @State private var isExpanded: Bool = true
    @State private var replyTarget: ReplyTarget? = nil

    private var messages: [MailMessage] { thread.sortedDedupedMessages }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isExpanded {
                Divider()
                ForEach(messages) { message in
                    MailMessageRowView(message: message)
                    Divider()
                }
                replyButton
            }
        }
        .sheet(item: $replyTarget) { target in
            #if canImport(SwiftMail)
            ComposeMailView(
                recipient: target.recipient,
                issue: issue,
                repoOwner: repoOwner,
                repoName: repoName,
                inReplyTo: target.headers,
                subjectOverride: target.subject
            )
            #else
            Text("ComposeMailView is unavailable on this build.")
            #endif
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
                .fixedSize(horizontal: true, vertical: false)
            Spacer()
        }
        .padding(.vertical, 4)
    }

    private var replyRecipient: String? {
        guard let last = messages.last else { return nil }
        // When the last message is outbound, reply to the first recipient (not our own from address).
        let rawRecipient = last.direction == .outbound
            ? (last.toAddresses.first ?? last.fromAddress)
            : last.fromAddress
        // SwiftMail's SMTP layer rejects `Display Name <addr>` form, so strip to bare addr.
        return MailAddress.bare(from: rawRecipient) ?? rawRecipient
    }

    private func beginReply() {
        guard let last = messages.last, let recipient = replyRecipient else { return }
        let headers = MailMessageHeaders(
            messageID: last.messageID,
            inReplyTo: last.inReplyTo,
            references: last.referencesAsArray
        )
        replyTarget = ReplyTarget(
            recipient: recipient,
            subject: MailSubject.replyPrefixed(last.subject),
            headers: headers
        )
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
    private var replyButton: some View {
        if let recipient = replyRecipient {
            ReplyBadgeButton(
                email: recipient,
                color: appColor,
                onReply: beginReply,
                onCopy: copyRecipient
            )
            .padding(.top, 8)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

