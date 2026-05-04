import Foundation
import SwiftData

@Model
final class MailMessage {
    var id: UUID = UUID()
    var messageID: String = ""
    var inReplyTo: String? = nil
    var references: String = ""
    var fromAddress: String = ""
    var fromName: String? = nil
    var toAddresses: [String] = []
    var ccAddresses: [String] = []
    var date: Date = Date()
    var subject: String = ""
    var bodyPlain: String = ""
    var bodyHTML: String? = nil
    var directionRaw: String = Direction.outbound.rawValue
    /// IMAP UID of the message. 0 for outbound messages (not fetched via IMAP).
    var uid: Int = 0
    /// IMAP folder name (e.g. "INBOX"). Empty for outbound messages.
    var folder: String = ""
    /// Numeric ID of the GitHub issue comment that mirrors this email, if any. Set after
    /// `MailToGitHubMirror` posts the comment; nil means "not mirrored yet" (or feature off
    /// for the repo). Used as the dedupe key so each poll cycle doesn't re-post inbound replies.
    var githubCommentID: Int? = nil
    /// Timestamp of successful SMTP delivery for outbound messages we composed locally.
    /// Nil for inbound, for legacy outbound rows backfilled from IMAP, and for outbound rows
    /// that haven't sent successfully yet. Synced via CloudKit so the "Sent" state survives
    /// relaunch and appears on the user's other devices.
    var sentAt: Date? = nil
    var thread: MailThread? = nil
    // CloudKit requires to-many relationships to be optional.
    @Relationship(deleteRule: .cascade, inverse: \MailAttachment.message)
    var attachments: [MailAttachment]? = []

    enum Direction: String, Sendable { case outbound, inbound }
    var direction: Direction {
        get { Direction(rawValue: directionRaw) ?? .outbound }
        set { directionRaw = newValue.rawValue }
    }

    var referencesAsArray: [String] {
        references.isEmpty ? [] : references.split(separator: "\n").map(String.init)
    }

    var headers: MailMessageHeaders {
        MailMessageHeaders(messageID: messageID, inReplyTo: inReplyTo, references: referencesAsArray)
    }

    init(
        id: UUID = UUID(),
        messageID: String = "",
        inReplyTo: String? = nil,
        references: String = "",
        fromAddress: String = "",
        fromName: String? = nil,
        toAddresses: [String] = [],
        ccAddresses: [String] = [],
        date: Date = Date(),
        subject: String = "",
        bodyPlain: String = "",
        bodyHTML: String? = nil,
        directionRaw: String = Direction.outbound.rawValue,
        uid: Int = 0,
        folder: String = "",
        sentAt: Date? = nil,
        thread: MailThread? = nil,
        attachments: [MailAttachment]? = []
    ) {
        self.id = id
        self.messageID = messageID
        self.inReplyTo = inReplyTo
        self.references = references
        self.fromAddress = fromAddress
        self.fromName = fromName
        self.toAddresses = toAddresses
        self.ccAddresses = ccAddresses
        self.date = date
        self.subject = subject
        self.bodyPlain = bodyPlain
        self.bodyHTML = bodyHTML
        self.directionRaw = directionRaw
        self.uid = uid
        self.folder = folder
        self.sentAt = sentAt
        self.thread = thread
        self.attachments = attachments
    }
}
