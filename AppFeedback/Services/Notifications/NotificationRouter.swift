import Foundation
import Observation

@Observable @MainActor
final class NotificationRouter {
    /// Composite issue key, e.g. `"owner/repo#42"`. Set by NotificationService when a
    /// notification is tapped. UI observes this and selects the matching issue.
    var pendingIssueKey: String?

    func consume() -> String? {
        defer { pendingIssueKey = nil }
        return pendingIssueKey
    }
}
