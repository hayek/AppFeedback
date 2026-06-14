import Foundation
@testable import AppFeedback

final class MockIntelligenceProvider: IntelligenceProvider, @unchecked Sendable {
    @MainActor var availability: IntelligenceAvailability = .available
    var summarizeHandler: ([FeedbackIssue], String) async throws -> IssueSummaryDTO = { issues, _ in
        IssueSummaryDTO(
            headline: "\(issues.count) issues (stub)",
            pros: "stub pros for \(issues.count) issues",
            cons: "stub cons for \(issues.count) issues"
        )
    }
    private(set) var summarizeCalls: [(issues: [FeedbackIssue], target: String)] = []

    func summarize(
        issues: [FeedbackIssue],
        targetLanguage: String,
        promptContext: AISummaryPromptContext
    ) async throws -> IssueSummaryDTO {
        await MainActor.run { self.summarizeCalls.append((issues, targetLanguage)) }
        _ = promptContext // record only when tests opt in via custom handler wrappers
        return try await summarizeHandler(issues, targetLanguage)
    }
}
