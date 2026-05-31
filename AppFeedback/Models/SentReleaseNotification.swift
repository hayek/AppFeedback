import Foundation
import SwiftData

@Model
final class SentReleaseNotification {
    var id: UUID = UUID()
    var repoOwner: String = ""
    var repoName: String = ""
    var versionName: String = ""
    var recipientEmail: String = ""
    var feedbackNumbers: [Int] = []
    var threadIssueNumber: Int = 0
    var sentAt: Date = Date()
    var statusRaw: String = "sent"        // "sent" | "failed"
    var errorDetail: String? = nil

    enum Status: String, Sendable { case sent, failed }
    var status: Status {
        get { Status(rawValue: statusRaw) ?? .sent }
        set { statusRaw = newValue.rawValue }
    }

    init(id: UUID = UUID(), repoOwner: String, repoName: String, versionName: String,
         recipientEmail: String, feedbackNumbers: [Int], threadIssueNumber: Int,
         sentAt: Date = Date(), status: Status = .sent, errorDetail: String? = nil) {
        self.id = id
        self.repoOwner = repoOwner
        self.repoName = repoName
        self.versionName = versionName
        self.recipientEmail = recipientEmail
        self.feedbackNumbers = feedbackNumbers
        self.threadIssueNumber = threadIssueNumber
        self.sentAt = sentAt
        self.statusRaw = status.rawValue
        self.errorDetail = errorDetail
    }
}
