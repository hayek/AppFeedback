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

    @Environment(MailSyncCoordinatorHolder.self) private var coordinatorHolder: MailSyncCoordinatorHolder?

    @State private var isExpanded: Bool = true
    @State private var replyTarget: ReplyTarget? = nil
    @State private var isRefreshing: Bool = false

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
        (thread.messages ?? []).sorted { $0.date < $1.date }
    }

    private var headerLine: String {
        let count = thread.messages?.count ?? 0
        let suffix = count == 1 ? "message" : "messages"
        let lastReply = relativeAgo(from: thread.lastMessageAt)
        return "\(count) \(suffix) — last reply \(lastReply)"
    }

    private var header: some View {
        HStack(spacing: 6) {
            Button(action: { withAnimation { isExpanded.toggle() } }) {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .foregroundStyle(.secondary)
                    Text(headerLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: refreshNow) {
                if isRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .disabled(coordinatorHolder?.coordinator == nil || isRefreshing)
            .help("Check for new replies")
        }
        .padding(.vertical, 4)
    }

    private func refreshNow() {
        guard let coordinator = coordinatorHolder?.coordinator else { return }
        isRefreshing = true
        Task {
            await coordinator.pollNow()
            isRefreshing = false
        }
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
