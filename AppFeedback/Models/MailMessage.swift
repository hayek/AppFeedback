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
    /// UIDVALIDITY of the folder `uid` belongs to. 0 when unknown. Guards attachment downloads
    /// against a stale `uid` after the mailbox's UID space is reassigned (recreated/restored).
    var uidValidity: Int = 0
    /// Numeric ID of the GitHub issue comment that mirrors this email, if any. Set after
    /// `MailToGitHubMirror` posts the comment; nil means "not mirrored yet" (or feature off
    /// for the repo). Used as the dedupe key so each poll cycle doesn't re-post inbound replies.
    var githubCommentID: Int? = nil
    /// Timestamp of successful SMTP delivery for outbound messages we composed locally.
    /// Nil for inbound, for legacy outbound rows backfilled from IMAP, and for outbound rows
    /// that haven't sent successfully yet. Synced via CloudKit so the "Sent" state survives
    /// relaunch and appears on the user's other devices.
    var sentAt: Date? = nil
    /// UUID of the `MailAccount` that sent or fetched this message. `nil` on legacy rows
    /// that pre-date the multi-account migration; the UI falls back to the global default
    /// sender when resolving a reply-from account.
    var accountID: UUID? = nil
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

    /// Attachments with duplicate `partID`s collapsed. CloudKit can sync the same message's
    /// attachment row from more than one device (no unique constraint on relationship children),
    /// so the UI dedupes at read time — mirroring `MailThread.sortedDedupedMessages`.
    var dedupedAttachments: [MailAttachment] {
        var seen: Set<String> = []
        return (attachments ?? []).filter { att in
            guard !att.partID.isEmpty else { return true }
            return seen.insert(att.partID).inserted
        }
    }

    var headers: MailMessageHeaders {
        MailMessageHeaders(messageID: messageID, inReplyTo: inReplyTo, references: referencesAsArray)
    }

    /// Where a reply to this message goes. Inbound → its sender; outbound → its first
    /// recipient, because replying to our own message must not address ourselves. Bare
    /// address: SwiftMail's SMTP layer rejects the `Display Name <addr>` form.
    ///
    /// The address the reporter *filed* with is deliberately not consulted — they may have
    /// carried on the conversation from another address, and the reply threads (In-Reply-To)
    /// into that conversation. `MailThreadView` and the CLI share this one rule.
    var replyRecipient: String {
        let raw = direction == .outbound ? (toAddresses.first ?? fromAddress) : fromAddress
        return MailAddress.bare(from: raw) ?? raw
    }

    /// Which account a reply to this message is sent FROM: the account that handled it, as
    /// long as that account still exists, else the global default sender. `nil` accountID is
    /// a legacy row that pre-dates multi-account support.
    @MainActor
    func replySenderAccountID(in store: MailAccountStore) -> UUID? {
        if let accountID, store.account(id: accountID) != nil { return accountID }
        return store.defaultSender?.id
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
        uidValidity: Int = 0,
        sentAt: Date? = nil,
        accountID: UUID? = nil,
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
        self.uidValidity = uidValidity
        self.sentAt = sentAt
        self.accountID = accountID
        self.thread = thread
        self.attachments = attachments
    }
}
