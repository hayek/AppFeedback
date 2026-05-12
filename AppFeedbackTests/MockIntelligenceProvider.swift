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
    var translateHandler: (String, String?, String) async throws -> String = { text, _, _ in
        "[t] " + text
    }
    private(set) var summarizeCalls: [(issues: [FeedbackIssue], target: String)] = []
    private(set) var translateCalls: [(text: String, from: String?, to: String)] = []

    func summarize(
        issues: [FeedbackIssue],
        targetLanguage: String,
        promptContext: AISummaryPromptContext
    ) async throws -> IssueSummaryDTO {
        // Serialize call-recording through MainActor so concurrent invocations
        // (e.g. parallel `async let` from IssueListViewModel.translate) don't race on Array.append.
        await MainActor.run { self.summarizeCalls.append((issues, targetLanguage)) }
        _ = promptContext // record only when tests opt in via custom handler wrappers
        return try await summarizeHandler(issues, targetLanguage)
    }
    func translate(text: String, from sourceCode: String?, to targetCode: String) async throws -> String {
        await MainActor.run { self.translateCalls.append((text, sourceCode, targetCode)) }
        return try await translateHandler(text, sourceCode, targetCode)
    }
}
