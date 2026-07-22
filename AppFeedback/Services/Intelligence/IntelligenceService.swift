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
      pros — genuine praise only: what users explicitly liked or reported as working / stable. Leave empty if there is none. Never reword complaints, bugs, or feature requests as positives.
      cons — problems, friction, bugs, plus unmet needs and feature requests (2–4 short sentences).
    Ground every claim in the provided issues; note rough frequencies when justified. Combine duplicates; skip speculation.
    No bullets, numbering, or markdown inside prose fields.
    Respond only in the requested target language.
    """
    private let unreadSummaryInstructions = """
    Summarize currently new / unread user feedback tickets the reviewer hasn't opened yet (short backlog snapshot).
    Output:
      headline — one concise sentence on what jumped out recently (volume + tone).
      pros — genuine praise only: positives explicitly surfaced in those unread items. Leave empty if there is none. Never reword complaints, bugs, or feature requests as positives.
      cons — problems surfaced in those unread items, plus unmet needs and feature requests (2–4 short sentences).
    Ground claims only in the provided issues; note rough repetition when justified. Combine duplicates; skip speculation.
    No bullets, numbering, or markdown inside prose fields.
    Respond only in the requested target language.
    """
    private let triageClassifyInstructions = """
    You triage a single piece of app-user feedback for a developer.
    Actionable means a developer could work on it: a bug, crash, or regression; a \
    concrete feature request; or a usability complaint (confusing, hard to find, \
    too many steps).
    Not actionable: praise ("the app works great"), content-free negativity \
    ("don't like it"), and questions or support requests.
    kind must be exactly one of: bug, featureRequest, usability, none.
    signal: one short factual sentence naming what is broken or wanted; empty when \
    not actionable. No markdown.
    """
    private let triageMatchInstructions = """
    You match an actionable piece of user feedback against a list of existing \
    development tasks. Most feedback is about something new: matching NO existing \
    task is the common, correct outcome. Say a task matches ONLY when it describes \
    the same specific feature or problem — a shared app area or vague similarity is \
    NOT a match. When a task matches, copy its exact title. When nothing matches, \
    propose a new task with a short imperative newTaskTitle and a 1-2 sentence \
    newTaskSummary grounded in the feedback. No markdown.
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

    nonisolated func triageClassify(issue: FeedbackIssue) async throws -> TriageClassificationDTO {
        try await MainActor.run { try checkAvailable() }
        #if canImport(FoundationModels)
        if #available(macOS 26, iOS 26, *) {
            return try await runTriageClassify(issue: issue)
        }
        #endif
        throw IntelligenceError.unavailable
    }

    nonisolated func triageMatch(signal: String, kind: TriageKind,
                                 roster: [TriageTaskRosterEntry]) async throws -> TriageDecisionDTO {
        try await MainActor.run { try checkAvailable() }
        #if canImport(FoundationModels)
        if #available(macOS 26, iOS 26, *) {
            return try await runTriageMatch(signal: signal, kind: kind, roster: roster)
        }
        #endif
        throw IntelligenceError.unavailable
    }

    @MainActor
    private func checkAvailable() throws {
        if !availability.isReady { throw IntelligenceError.unavailable }
    }
}

enum IntelligenceError: Error, Equatable {
    case unavailable
    case empty
    case guardrailBlocked
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

    fileprivate func runTriageClassify(issue: FeedbackIssue) async throws -> TriageClassificationDTO {
        let instructions = await MainActor.run { triageClassifyInstructions }
        let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
        var lastBudgetError: Error?
        for bodyCharCap in TriagePromptBuilder.classifyConfigs() {
            let prompt = TriagePromptBuilder.buildClassifyPrompt(issue: issue, bodyCharCap: bodyCharCap)
            let session = LanguageModelSession(model: model, instructions: instructions)
            do {
                let response = try await session.respond(to: prompt, generating: TriageClassification.self)
                return TriageClassificationDTO(response.content)
            } catch let error as LanguageModelSession.GenerationError {
                if case .guardrailViolation = error { throw IntelligenceError.guardrailBlocked }
                if case .exceededContextWindowSize = error { lastBudgetError = error; continue }
                throw error
            }
        }
        throw lastBudgetError ?? IntelligenceError.unavailable
    }

    fileprivate func runTriageMatch(signal: String, kind: TriageKind,
                                    roster: [TriageTaskRosterEntry]) async throws -> TriageDecisionDTO {
        let instructions = await MainActor.run { triageMatchInstructions }
        let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
        let fallbackTitle = String(signal.prefix(72))
        var lastBudgetError: Error?
        for rosterCap in TriagePromptBuilder.matchConfigs() {
            let (prompt, included) = TriagePromptBuilder.buildMatchPrompt(
                signal: signal, kind: kind, roster: roster, rosterCap: rosterCap)
            let session = LanguageModelSession(model: model, instructions: instructions)
            do {
                let response = try await session.respond(to: prompt, generating: TriageMatchDecision.self)
                return TriageDecisionDTO(response.content, includedRoster: included,
                                         fallbackTitle: fallbackTitle, fallbackSummary: signal)
            } catch let error as LanguageModelSession.GenerationError {
                if case .guardrailViolation = error { throw IntelligenceError.guardrailBlocked }
                if case .exceededContextWindowSize = error { lastBudgetError = error; continue }
                throw error
            }
        }
        throw lastBudgetError ?? IntelligenceError.unavailable
    }
}
#endif
