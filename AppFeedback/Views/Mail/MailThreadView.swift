import SwiftUI

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

    private var headerLine: String {
        let count = thread.messages?.count ?? 0
        let suffix = count == 1 ? "message" : "messages"
        let lastReply = relativeAgo(from: thread.lastMessageAt)
        return "\(count) \(suffix) — last reply \(lastReply)"
    }

    private var header: some View {
        Button(action: { withAnimation { isExpanded.toggle() } }) {
            HStack(spacing: 6) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .foregroundStyle(.secondary)
                Text(headerLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var replyButton: some View {
        Button("Reply") {
            guard let last = messages.last else { return }
            let headers = MailMessageHeaders(
                messageID: last.messageID,
                inReplyTo: last.inReplyTo,
                references: last.referencesAsArray
            )
            // When the last message is outbound, reply to the first recipient (not our own from address).
            let rawRecipient = last.direction == .outbound
                ? (last.toAddresses.first ?? last.fromAddress)
                : last.fromAddress
            // SwiftMail's SMTP layer rejects `Display Name <addr>` form, so strip to bare addr.
            let replyRecipient = MailAddress.bare(from: rawRecipient) ?? rawRecipient
            replyTarget = ReplyTarget(
                recipient: replyRecipient,
                subject: MailSubject.replyPrefixed(last.subject),
                headers: headers
            )
        }
        .buttonStyle(.bordered)
        .padding(.top, 8)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

private let relativeDateFormatter: RelativeDateTimeFormatter = {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .short
    return f
}()

private func relativeAgo(from date: Date) -> String {
    relativeDateFormatter.localizedString(for: date, relativeTo: Date())
}
