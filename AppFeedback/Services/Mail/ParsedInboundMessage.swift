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
}

struct ParsedAttachmentMeta: Sendable, Equatable {
    let partID: String
    let filename: String
    let mimeType: String
    let sizeBytes: Int
}
