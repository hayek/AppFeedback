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

    @State private var isExpanded: Bool = false
    @State private var replyTarget: ReplyTarget? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isExpanded {
                Divider()
                ForEach(sortedMessages) { message in
                    MailMessageRowView(message: message)
                    Divider()
                }
                replyButton
            }
        }
        .background(Color.gray.opacity(0.05))
        .cornerRadius(6)
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

    private var sortedMessages: [MailMessage] {
        thread.messages.sorted { $0.date < $1.date }
    }

    private var headerLine: String {
        let count = thread.messages.count
        let suffix = count == 1 ? "message" : "messages"
        let lastReply = relativeAgo(from: thread.lastMessageAt)
        return "\(count) \(suffix) — last reply \(lastReply)"
    }

    private var header: some View {
        Button(action: { withAnimation { isExpanded.toggle() } }) {
            HStack {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .foregroundStyle(.secondary)
                Text(headerLine).font(.subheadline).foregroundStyle(.primary)
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var replyButton: some View {
        Button("Reply") {
            guard let last = sortedMessages.last else { return }
            let headers = MailMessageHeaders(
                messageID: last.messageID,
                inReplyTo: last.inReplyTo,
                references: last.referencesAsArray
            )
            // When the last message is outbound, reply to the first recipient (not our own from address).
            let replyRecipient = last.direction == .outbound
                ? (last.toAddresses.first ?? last.fromAddress)
                : last.fromAddress
            replyTarget = ReplyTarget(
                recipient: replyRecipient,
                subject: MailSubject.replyPrefixed(last.subject),
                headers: headers
            )
        }
        .buttonStyle(.bordered)
        .padding(8)
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
