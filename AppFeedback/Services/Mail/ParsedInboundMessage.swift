import Foundation

struct ParsedInboundMessage: Sendable, Equatable {
    let uid: UInt32
    let folder: String
    let uidValidity: UInt32
    let messageID: String
    let inReplyTo: String?
    let references: [String]
    let fromAddress: String
    let fromName: String?
    let toAddresses: [String]
    let ccAddresses: [String]
    let date: Date
    let subject: String
    let bodyPlain: String
    let bodyHTML: String?
    let attachments: [ParsedAttachmentMeta]
    /// Raw `Return-Path:` header value (angle brackets stripped). Empty ("<>") on bounces.
    let returnPath: String?
    /// Raw `Auto-Submitted:` header value, lowercased. e.g. "auto-replied".
    let autoSubmitted: String?
    /// Raw `Precedence:` header value, lowercased. e.g. "bulk" / "list".
    let precedence: String?

    init(
        uid: UInt32, folder: String, uidValidity: UInt32, messageID: String,
        inReplyTo: String?, references: [String],
        fromAddress: String, fromName: String?,
        toAddresses: [String], ccAddresses: [String],
        date: Date, subject: String, bodyPlain: String, bodyHTML: String?,
        attachments: [ParsedAttachmentMeta],
        returnPath: String? = nil, autoSubmitted: String? = nil, precedence: String? = nil
    ) {
        self.uid = uid; self.folder = folder; self.uidValidity = uidValidity
        self.messageID = messageID; self.inReplyTo = inReplyTo; self.references = references
        self.fromAddress = fromAddress; self.fromName = fromName
        self.toAddresses = toAddresses; self.ccAddresses = ccAddresses
        self.date = date; self.subject = subject
        self.bodyPlain = bodyPlain; self.bodyHTML = bodyHTML
        self.attachments = attachments
        self.returnPath = returnPath; self.autoSubmitted = autoSubmitted; self.precedence = precedence
    }
}

struct ParsedAttachmentMeta: Sendable, Equatable {
    let partID: String
    let filename: String
    let mimeType: String
    let sizeBytes: Int
    let contentID: String?

    init(partID: String, filename: String, mimeType: String, sizeBytes: Int, contentID: String? = nil) {
        self.partID = partID
        self.filename = filename
        self.mimeType = mimeType
        self.sizeBytes = sizeBytes
        self.contentID = contentID
    }
}
