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
    var triageClassifyHandler: (FeedbackIssue) async throws -> TriageClassificationDTO = { _ in
        TriageClassificationDTO(isActionable: false, kind: nil, signal: "")
    }
    var triageMatchHandler: (String, TriageKind, [TriageTaskRosterEntry]) async throws -> TriageDecisionDTO = { signal, _, _ in
        .createNew(title: String(signal.prefix(72)), summary: signal)
    }
    private(set) var triageClassifyCalls: [FeedbackIssue] = []
    private(set) var triageMatchCalls: [(signal: String, kind: TriageKind, roster: [TriageTaskRosterEntry])] = []

    func summarize(
        issues: [FeedbackIssue],
        targetLanguage: String,
        promptContext: AISummaryPromptContext
    ) async throws -> IssueSummaryDTO {
        await MainActor.run { self.summarizeCalls.append((issues, targetLanguage)) }
        _ = promptContext // record only when tests opt in via custom handler wrappers
        return try await summarizeHandler(issues, targetLanguage)
    }

    func triageClassify(issue: FeedbackIssue) async throws -> TriageClassificationDTO {
        await MainActor.run { self.triageClassifyCalls.append(issue) }
        return try await triageClassifyHandler(issue)
    }

    func triageMatch(signal: String, kind: TriageKind,
                     roster: [TriageTaskRosterEntry]) async throws -> TriageDecisionDTO {
        await MainActor.run { self.triageMatchCalls.append((signal, kind, roster)) }
        return try await triageMatchHandler(signal, kind, roster)
    }
}
