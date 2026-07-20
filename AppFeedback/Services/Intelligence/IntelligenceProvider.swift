import Foundation

/// On-device intelligence used for AI summaries. Translation no longer lives here —
/// it runs through Apple's Translation framework (`TranslationHost`), which needs no
/// Apple Intelligence. This provider gates and produces the rolling/unread summaries only.
protocol IntelligenceProvider: AnyObject, Sendable {
    @MainActor var availability: IntelligenceAvailability { get }
    func summarize(
        issues: [FeedbackIssue],
        targetLanguage: String,
        promptContext: AISummaryPromptContext
    ) async throws -> IssueSummaryDTO
    /// Stage 1: is this single feedback item task-worthy, and what's the signal?
    func triageClassify(issue: FeedbackIssue) async throws -> TriageClassificationDTO
    /// Stage 2: assign to one of `roster` or propose a new task. Returned `.assign`
    /// numbers are guaranteed to be members of `roster`.
    func triageMatch(signal: String, kind: TriageKind,
                     roster: [TriageTaskRosterEntry]) async throws -> TriageDecisionDTO
}
