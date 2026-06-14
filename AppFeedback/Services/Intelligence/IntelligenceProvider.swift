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
}
