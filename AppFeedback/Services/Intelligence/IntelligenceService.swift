import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

@MainActor
@Observable
final class IntelligenceService: IntelligenceProvider {
    private(set) var availability: IntelligenceAvailability = .osTooOld
    private let rollingSummaryInstructions = """
    Summarize rolling 30-day user feedback tickets for a PM audience.
    Output:
      headline — one concise sentence capturing overall posture (volume, moods, hotspots).
      pros — factual positives/praise/stable areas drawn from explicit reports (2–4 short sentences).
      cons — factual problems/friction/bugs (2–4 short sentences).
    Ground every claim in the provided issues; note rough frequencies when justified. Combine duplicates; skip speculation.
    No bullets, numbering, or markdown inside prose fields.
    Respond only in the requested target language.
    """
    private let unreadSummaryInstructions = """
    Summarize currently new / unread user feedback tickets the reviewer hasn't opened yet (short backlog snapshot).
    Output:
      headline — one concise sentence on what jumped out recently (volume + tone).
      pros — factual positives surfaced in those unread items (2–4 short sentences).
      cons — factual problems surfaced in those unread items (2–4 short sentences).
    Ground claims only in the provided issues; note rough repetition when justified. Combine duplicates; skip speculation.
    No bullets, numbering, or markdown inside prose fields.
    Respond only in the requested target language.
    """

    init() {}

    func recomputeAvailability() {
        #if canImport(FoundationModels)
        guard #available(macOS 26, iOS 26, *) else {
            availability = .osTooOld
            return
        }
        guard case .unavailable(let reason) = SystemLanguageModel.default.availability else {
            availability = .available
            return
        }
        switch reason {
        case .appleIntelligenceNotEnabled: availability = .appleIntelligenceNotEnabled
        case .modelNotReady: availability = .modelNotReady
        case .deviceNotEligible: availability = .deviceNotEligible
        @unknown default: availability = .deviceNotEligible
        }
        #else
        availability = .osTooOld
        #endif
    }

    nonisolated func summarize(
        issues: [FeedbackIssue],
        targetLanguage: String,
        promptContext: AISummaryPromptContext
    ) async throws -> IssueSummaryDTO {
        try await MainActor.run { try checkAvailable() }
        #if canImport(FoundationModels)
        if #available(macOS 26, iOS 26, *) {
            return try await runSummarize(
                issues: issues,
                targetLanguage: targetLanguage,
                promptContext: promptContext
            )
        }
        #endif
        throw IntelligenceError.unavailable
    }

    @MainActor
    private func checkAvailable() throws {
        if !availability.isReady { throw IntelligenceError.unavailable }
    }
}

enum IntelligenceError: Error {
    case unavailable
    case empty
}

#if canImport(FoundationModels)
@available(macOS 26, iOS 26, *)
extension IntelligenceService {
    fileprivate func runSummarize(
        issues: [FeedbackIssue],
        targetLanguage: String,
        promptContext: AISummaryPromptContext
    ) async throws -> IssueSummaryDTO {
        guard !issues.isEmpty else { throw IntelligenceError.empty }
        let instructionsTemplate = promptContext == .unreadIssues
            ? unreadSummaryInstructions
            : rollingSummaryInstructions
        let instructions = await MainActor.run { instructionsTemplate }
        let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
        let attemptConfigs = SummaryPromptBuilder.contextSafeConfigs()
        var lastBudgetError: Error?
        for config in attemptConfigs {
            let prompt = SummaryPromptBuilder.build(
                issues: issues,
                targetLanguage: targetLanguage,
                issueCap: config.issueCap,
                bodyCharCap: config.bodyCharCap,
                promptContext: promptContext
            )
            /// One session per attempt so prior failures never accumulate transcript into the budget.
            let session = LanguageModelSession(model: model, instructions: instructions)
            do {
                let response = try await session.respond(to: prompt, generating: IssueSummary.self)
                return IssueSummaryDTO(response.content)
            } catch let error as LanguageModelSession.GenerationError {
                if case .guardrailViolation = error {
                    let headlinePrefix = promptContext == .unreadIssues
                        ? "\(issues.count) unread feedback issues"
                        : "\(issues.count) feedback items (last ~30 days)"
                    return IssueSummaryDTO(
                        headline: headlinePrefix,
                        pros: "",
                        cons: ""
                    )
                }
                if case .exceededContextWindowSize = error {
                    lastBudgetError = error
                    continue
                }
                throw error
            }
        }
        throw lastBudgetError ?? IntelligenceError.unavailable
    }
}
#endif
