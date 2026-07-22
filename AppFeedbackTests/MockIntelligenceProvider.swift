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
    var triageMatchHandler: (String, String, TriageKind, [TriageTaskRosterEntry]) async throws -> TriageDecisionDTO = { _, signal, _, _ in
        .createNew(title: String(signal.prefix(72)), summary: signal)
    }
    var triageVerifyHandler: (String, String, TriageKind, TriageTaskRosterEntry) async throws -> Bool = { _, _, _, _ in false }
    private(set) var triageClassifyCalls: [FeedbackIssue] = []
    private(set) var triageMatchCalls: [(feedbackTitle: String, signal: String, kind: TriageKind, roster: [TriageTaskRosterEntry])] = []
    private(set) var triageVerifyCalls: [(feedbackTitle: String, candidate: TriageTaskRosterEntry)] = []

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

    func triageMatch(feedbackTitle: String, signal: String, kind: TriageKind,
                     roster: [TriageTaskRosterEntry]) async throws -> TriageDecisionDTO {
        await MainActor.run { self.triageMatchCalls.append((feedbackTitle, signal, kind, roster)) }
        return try await triageMatchHandler(feedbackTitle, signal, kind, roster)
    }

    func triageVerify(feedbackTitle: String, signal: String, kind: TriageKind,
                      candidate: TriageTaskRosterEntry) async throws -> Bool {
        await MainActor.run { self.triageVerifyCalls.append((feedbackTitle, candidate)) }
        return try await triageVerifyHandler(feedbackTitle, signal, kind, candidate)
    }
}
