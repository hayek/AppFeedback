import Foundation

enum ReplyHeaderBuilder {
    struct Output: Equatable, Sendable {
        var inReplyTo: String?
        var references: [String]
    }

    static func build(parent: MailMessageHeaders?, newMessageID: String) -> Output? {
        guard let parent else { return nil }
        let parentIsSynthetic = MessageIDGenerator.isSynthetic(parent.messageID)
        let inReplyTo = parentIsSynthetic ? nil : parent.messageID
        var references = parent.references
        if !parentIsSynthetic {
            references.append(parent.messageID)
        }
        return Output(inReplyTo: inReplyTo, references: references)
    }
}
