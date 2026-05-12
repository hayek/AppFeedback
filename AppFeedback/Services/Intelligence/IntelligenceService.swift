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
    private let translationInstructions = """
    You are a translator. Translate the user's text into the requested target language.
    Preserve meaning, tone, and any URLs, code identifiers, or @mentions verbatim.

    Return a structured result:
      • didTranslate: true only when you produced a real translation in the target language. Set to false for anything else — including when the input is a single letter, a symbol, already in the target language, untranslatable, or you would otherwise need to apologize or explain.
      • translation: the translated text only. No preamble, no quotation marks, no apologies, no explanations, no notes about the input. If didTranslate is false, leave translation empty.

    Never explain why you could not translate. Either translate, or set didTranslate to false with an empty translation.
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

    nonisolated func translate(text: String, from sourceCode: String?, to targetCode: String) async throws -> String {
        try await MainActor.run { try checkAvailable() }
        #if canImport(FoundationModels)
        if #available(macOS 26, iOS 26, *) {
            return try await runTranslate(text: text, from: sourceCode, to: targetCode)
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
    fileprivate func runTranslate(text: String, from sourceCode: String?, to targetCode: String) async throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return text }
        let instructions = await MainActor.run { translationInstructions }
        let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
        let session = LanguageModelSession(model: model, instructions: instructions)
        let targetName = Locale(identifier: "en").localizedString(forLanguageCode: targetCode) ?? targetCode
        let sourceName = sourceCode.flatMap {
            Locale(identifier: "en").localizedString(forLanguageCode: $0)
        }
        let prompt: String
        if let sourceName {
            prompt = "Translate this from \(sourceName) to \(targetName):\n\n\(trimmed)"
        } else {
            prompt = "Translate this to \(targetName):\n\n\(trimmed)"
        }
        let response = try await session.respond(to: prompt, generating: TranslationResult.self)
        let result = response.content
        let translated = result.translation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.didTranslate, !translated.isEmpty else {
            throw IntelligenceError.empty
        }
        return translated
    }
}
#endif
