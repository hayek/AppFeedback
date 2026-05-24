import Foundation

/// Single shape used by every "open the compose UI" call site — both first-time emails
/// (no thread yet) and replies in an existing thread. Optional fields are nil when the
/// compose is brand-new.
struct ComposeRequest: Identifiable {
    let id = UUID()
    let recipient: String
    let issue: FeedbackIssue
    let repoOwner: String
    let repoName: String
    let inReplyTo: MailMessageHeaders?
    let subjectOverride: String?
    let senderAccountID: UUID?
    var attachments: [PendingAttachment] = []
}

struct PendingAttachment: Identifiable, Sendable, Equatable {
    let id: UUID
    let filename: String
    let mimeType: String
    let data: Data

    init(id: UUID = UUID(), filename: String, mimeType: String, data: Data) {
        self.id = id
        self.filename = filename
        self.mimeType = mimeType
        self.data = data
    }
}
