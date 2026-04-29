import Foundation
import SwiftData

@Model
final class MailThread {
    var id: UUID = UUID()
    var messageIDRoot: String = ""
    var subject: String = ""
    var participants: [String] = []
    var lastMessageAt: Date = Date.distantPast
    var issueRepoOwner: String = ""
    var issueRepoName: String = ""
    var issueNumber: Int = 0           // 0 = unlinked
    var matchSourceRaw: String = MatchSource.direct.rawValue
    // CloudKit requires to-many relationships to be optional.
    @Relationship(deleteRule: .cascade, inverse: \MailMessage.thread)
    var messages: [MailMessage]? = []

    enum MatchSource: String, Sendable { case direct, header, subjectFallback, backfillFuzzy }
    var matchSource: MatchSource {
        get { MatchSource(rawValue: matchSourceRaw) ?? .direct }
        set { matchSourceRaw = newValue.rawValue }
    }

    var isLinkedToIssue: Bool { issueNumber > 0 }

    init(
        id: UUID = UUID(),
        messageIDRoot: String = "",
        subject: String = "",
        participants: [String] = [],
        lastMessageAt: Date = Date.distantPast,
        issueRepoOwner: String = "",
        issueRepoName: String = "",
        issueNumber: Int = 0,
        matchSourceRaw: String = MatchSource.direct.rawValue,
        messages: [MailMessage]? = []
    ) {
        self.id = id
        self.messageIDRoot = messageIDRoot
        self.subject = subject
        self.participants = participants
        self.lastMessageAt = lastMessageAt
        self.issueRepoOwner = issueRepoOwner
        self.issueRepoName = issueRepoName
        self.issueNumber = issueNumber
        self.matchSourceRaw = matchSourceRaw
        self.messages = messages
    }
}
