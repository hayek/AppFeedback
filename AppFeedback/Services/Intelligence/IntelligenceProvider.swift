import Foundation

protocol IntelligenceProvider: AnyObject, Sendable {
    @MainActor var availability: IntelligenceAvailability { get }
    func summarize(
        issues: [FeedbackIssue],
        targetLanguage: String,
        promptContext: AISummaryPromptContext
    ) async throws -> IssueSummaryDTO
    func translate(text: String, from sourceCode: String?, to targetCode: String) async throws -> String
}
