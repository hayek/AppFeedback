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
    /// When set, seeds the composer body (placeholder-substituted) — used by template replies.
    var initialBody: String? = nil
    /// When true, the composer sends immediately on appear (if credentialed) — the modal's "Send" CTA.
    var autoSend: Bool = false
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

/// A picked file's bytes before they become a ``PendingAttachment`` — the shape both
/// attachment sources (the Files importer and the iOS photo picker) hand to
/// `ComposeMailViewModel.ingest(_:)`, which preprocesses and validates them.
struct RawAttachmentInput: Sendable, Equatable {
    let filename: String
    let mimeType: String
    let data: Data
}
