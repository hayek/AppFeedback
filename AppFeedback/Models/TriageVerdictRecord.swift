import Foundation
import SwiftData

/// Lifecycle of an AI triage verdict for one feedback issue.
enum TriageState: String, Sendable, CaseIterable {
    /// Present before triage was first enabled for its repo; only manual backfill touches it.
    case preexisting
    /// Classified as praise / vague negativity / question — no task warranted.
    case notActionable
    /// Suggestion awaiting user accept/dismiss.
    case pending
    case accepted
    case dismissed
    /// Applied without confirmation (hybrid assign or full-auto).
    case autoApplied
    /// Guardrail block or repeated context/transport failure; backfill may retry.
    case skipped
}

/// Local-only AI triage verdict for one feedback issue. Lives in the local
/// (non-CloudKit) schema — AI output never syncs or touches GitHub.
@Model
final class TriageVerdictRecord {
    var repoOwner: String = ""
    var repoName: String = ""
    var feedbackNumber: Int = 0
    /// Raw `TriageState`.
    var state: String = ""
    var isActionable: Bool = false
    /// Raw `TriageKind`; nil when not actionable.
    var kind: String?
    var signal: String = ""
    /// Pending/applied outcome: the existing task to assign to…
    var suggestedTaskNumber: Int?
    /// …or the new task to create.
    var suggestedTitle: String?
    var suggestedSummary: String?
    /// Task number an accepted/auto-applied create produced — drives the local "AI" badge.
    var createdTaskNumber: Int?
    var updatedAt: Date = Date()

    init(repoOwner: String, repoName: String, feedbackNumber: Int, state: String) {
        self.repoOwner = repoOwner
        self.repoName = repoName
        self.feedbackNumber = feedbackNumber
        self.state = state
    }
}
