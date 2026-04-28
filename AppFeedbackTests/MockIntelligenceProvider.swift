import Foundation
@testable import AppFeedback

final class MockIntelligenceProvider: IntelligenceProvider, @unchecked Sendable {
    @MainActor var availability: IntelligenceAvailability = .available
    var summarizeHandler: ([FeedbackIssue], String) async throws -> IssueSummaryDTO = { issues, _ in
        IssueSummaryDTO(
            headline: "\(issues.count) unread issues",
            sections: [.init(title: "Stub theme", body: "stub body for \(issues.count) issues")]
        )
    }
    var translateHandler: (String, String?, String) async throws -> String = { text, _, _ in
        "[t] " + text
    }
    private(set) var summarizeCalls: [(issues: [FeedbackIssue], target: String)] = []
    private(set) var translateCalls: [(text: String, from: String?, to: String)] = []

    func summarize(issues: [FeedbackIssue], targetLanguage: String) async throws -> IssueSummaryDTO {
        summarizeCalls.append((issues, targetLanguage))
        return try await summarizeHandler(issues, targetLanguage)
    }
    func translate(text: String, from sourceCode: String?, to targetCode: String) async throws -> String {
        translateCalls.append((text, sourceCode, targetCode))
        return try await translateHandler(text, sourceCode, targetCode)
    }
}
