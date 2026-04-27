import Foundation
import SwiftData

@Model
final class SeenIssue {
    var repoOwner: String = ""
    var repoName: String = ""
    var issueNumber: Int = 0
    var seenAt: Date = Date()

    init(repoOwner: String, repoName: String, issueNumber: Int, seenAt: Date = Date()) {
        self.repoOwner = repoOwner
        self.repoName = repoName
        self.issueNumber = issueNumber
        self.seenAt = seenAt
    }
}
