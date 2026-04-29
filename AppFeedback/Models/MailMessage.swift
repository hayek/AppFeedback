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
    var directionRaw: String = "outbound"
    var thread: MailThread? = nil
    @Relationship(deleteRule: .cascade, inverse: \MailAttachment.message)
    var attachments: [MailAttachment] = []

    enum Direction: String, Sendable { case outbound, inbound }
    var direction: Direction {
        get { Direction(rawValue: directionRaw) ?? .outbound }
        set { directionRaw = newValue.rawValue }
    }

    var headers: MailMessageHeaders {
        MailMessageHeaders(
            messageID: messageID,
            inReplyTo: inReplyTo,
            references: references.isEmpty ? [] : references.split(separator: "\n").map(String.init)
        )
    }

    var referencesAsArray: [String] {
        references.isEmpty ? [] : references.split(separator: "\n").map(String.init)
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
        directionRaw: String = "outbound",
        thread: MailThread? = nil,
        attachments: [MailAttachment] = []
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
        self.thread = thread
        self.attachments = attachments
    }
}
