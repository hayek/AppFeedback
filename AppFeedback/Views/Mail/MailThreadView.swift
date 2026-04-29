import SwiftUI

struct MailThreadView: View {
    let thread: MailThread
    let repoOwner: String
    let repoName: String

    @State private var isExpanded: Bool = false

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
            // Wired in Task 8.
        }
        .buttonStyle(.bordered)
        .padding(8)
        .disabled(true)  // Placeholder until Task 8.
    }
}

private func relativeAgo(from date: Date) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .short
    return formatter.localizedString(for: date, relativeTo: Date())
}
