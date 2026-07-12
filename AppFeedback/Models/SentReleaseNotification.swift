import Foundation
import SwiftData

@Model
final class SentReleaseNotification {
    var id: UUID = UUID()
    var repoOwner: String = ""
    var repoName: String = ""
    /// The `ProjectVersion.id` this row belongs to. Optional because CloudKit forbids non-optional
    /// new properties, so rows written by older builds arrive as nil and are matched by name
    /// instead (see `VersionStore.matches`). Stamped on write, never on read.
    var versionID: UUID? = nil
    /// Display copy of the version's name at send time. Kept in sync by a rename, but `versionID`
    /// — not this — is what identifies the version.
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

    init(id: UUID = UUID(), repoOwner: String, repoName: String, versionID: UUID? = nil, versionName: String,
         recipientEmail: String, feedbackNumbers: [Int], threadIssueNumber: Int,
         sentAt: Date = Date(), status: Status = .sent, errorDetail: String? = nil) {
        self.id = id
        self.repoOwner = repoOwner
        self.repoName = repoName
        self.versionID = versionID
        self.versionName = versionName
        self.recipientEmail = recipientEmail
        self.feedbackNumbers = feedbackNumbers
        self.threadIssueNumber = threadIssueNumber
        self.sentAt = sentAt
        self.statusRaw = status.rawValue
        self.errorDetail = errorDetail
    }
}
