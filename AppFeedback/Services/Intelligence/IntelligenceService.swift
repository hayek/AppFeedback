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

    Critical rules:
      • Translate the ENTIRE input. If the input contains multiple paragraphs (separated by blank lines), output the same number of paragraphs in the same order, separated by blank lines. Never drop, merge, or summarize paragraphs.
      • Preserve meaning, tone, paragraph breaks, line breaks, and any URLs, code identifiers, or @mentions verbatim.

    Return a structured result:
      • didTranslate: true only when you produced a real translation in the target language. Set to false for anything else — single letters, symbols, already-in-target inputs, or untranslatable text.
      • translation: the translated text only. No preamble, no quotation marks, no apologies, no explanations. Must contain every paragraph from the input. If didTranslate is false, leave translation empty.

    Never explain why you could not translate. Either translate (in full), or set didTranslate to false with an empty translation.
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
    case unsupportedLanguage
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
        let paraCount = trimmed.components(separatedBy: "\n\n").count
        let countHint = paraCount > 1
            ? " The input has \(paraCount) paragraphs; your output must have the same \(paraCount) paragraphs separated by blank lines."
            : ""
        let prompt: String
        if let sourceName {
            prompt = "Translate this from \(sourceName) to \(targetName).\(countHint)\n\n\(trimmed)"
        } else {
            prompt = "Translate this to \(targetName).\(countHint)\n\n\(trimmed)"
        }
        let inputLines = trimmed.components(separatedBy: "\n").count
        let inputParas = trimmed.components(separatedBy: "\n\n").count
        print("[Translate] → input chars=\(trimmed.count) lines=\(inputLines) paragraphs=\(inputParas) src=\(sourceCode ?? "auto") dst=\(targetCode)")
        print("[Translate] → input preview: \(trimmed.prefix(120))\(trimmed.count > 120 ? "…" : "")")
        do {
            let response = try await session.respond(to: prompt, generating: TranslationResult.self)
            let result = response.content
            let translated = result.translation.trimmingCharacters(in: .whitespacesAndNewlines)
            let outLines = translated.components(separatedBy: "\n").count
            let outParas = translated.components(separatedBy: "\n\n").count
            let ratio = trimmed.isEmpty ? 0.0 : Double(translated.count) / Double(trimmed.count)
            print("[Translate] ← didTranslate=\(result.didTranslate) chars=\(translated.count) lines=\(outLines) paragraphs=\(outParas) ratio=\(String(format: "%.2f", ratio))")
            print("[Translate] ← output preview: \(translated.prefix(120))\(translated.count > 120 ? "…" : "")")
            if result.didTranslate && inputParas > 1 && outParas < inputParas {
                print("[Translate] ⚠ paragraph count dropped: input=\(inputParas) → output=\(outParas) (likely truncated)")
            }
            guard result.didTranslate, !translated.isEmpty else {
                throw IntelligenceError.empty
            }
            return translated
        } catch {
            print("[Translate] ✗ error: \(error)")
            if let gen = error as? LanguageModelSession.GenerationError,
               case .unsupportedLanguageOrLocale = gen {
                throw IntelligenceError.unsupportedLanguage
            }
            throw error
        }
    }
}
#endif
