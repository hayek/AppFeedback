import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif


/// Backs the macOS compose window scene. Multiple requests can be queued; each one is
/// presented in its own window (keyed by `request.id`). The window removes its entry on
/// close so the holder doesn't leak.
@MainActor
@Observable
final class ComposeWindowHolder {
    static let windowID = "compose"

    private(set) var requests: [ComposeRequest] = []

    func request(id: UUID) -> ComposeRequest? {
        requests.first { $0.id == id }
    }

    func remove(id: UUID) {
        requests.removeAll { $0.id == id }
    }

    #if os(macOS)
    /// Enqueues `request` and opens a compose window keyed by its id. Single dispatch entry
    /// point so call sites don't repeat the enqueue + openWindow pair.
    func present(_ request: ComposeRequest, openWindow: OpenWindowAction) {
        requests.append(request)
        openWindow(id: Self.windowID, value: request.id)
    }
    #endif
}

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

    private var messages: [MailMessage] { thread.sortedDedupedMessages }

    private var resolvedSenderAccountID: UUID? {
        if let last = messages.last,
           let id = last.accountID,
           accountStore.account(id: id) != nil {
            return id
        }
        return accountStore.defaultSender?.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isExpanded {
                Divider()
                ForEach(messages) { message in
                    MailMessageRowView(message: message)
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

    private var replyRecipient: String? {
        guard let last = messages.last else { return nil }
        // When the last message is outbound, reply to the first recipient (not our own from address).
        let rawRecipient = last.direction == .outbound
            ? (last.toAddresses.first ?? last.fromAddress)
            : last.fromAddress
        // SwiftMail's SMTP layer rejects `Display Name <addr>` form, so strip to bare addr.
        return MailAddress.bare(from: rawRecipient) ?? rawRecipient
    }

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
                onReplyFrom: { id in beginReply(senderAccountID: id) }
            )
            .padding(.top, 8)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}

#if os(macOS) && canImport(SwiftMail)
/// Hosted inside the "compose" `WindowGroup` scene. Looks up the queued `ComposeRequest`
/// by id and renders `ComposeMailView`. When the window closes, the entry is removed from
/// the holder so it doesn't leak.
struct ComposeWindowContent: View {
    let requestID: UUID?

    @Environment(ComposeWindowHolder.self) private var holder

    var body: some View {
        Group {
            if let id = requestID, let request = holder.request(id: id) {
                ComposeMailView(request: request)
                    .navigationTitle("Reply — \(request.issue.title)")
                    .onDisappear { holder.remove(id: id) }
            } else {
                Text("This compose window is no longer available.")
                    .foregroundStyle(.secondary)
                    .padding()
            }
        }
    }
}
#endif

