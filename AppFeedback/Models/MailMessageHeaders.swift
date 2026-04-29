import Foundation

struct MailMessageHeaders: Equatable, Sendable {
    var messageID: String
    var inReplyTo: String?
    var references: [String]
}
