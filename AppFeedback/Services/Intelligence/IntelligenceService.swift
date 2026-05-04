import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

@MainActor
@Observable
final class IntelligenceService: IntelligenceProvider {
    private(set) var availability: IntelligenceAvailability = .osTooOld
    private let summaryInstructions = """
    You are a concise product manager summarizing new user feedback.
    Produce a structured summary:
      • headline: one sentence covering all of the new feedback overall.
      • sections: 2-5 themed sections. Each section combines similar/related issues into one theme.
        - title: a short, specific theme name (e.g. "Login failures", "Crash on launch").
        - body: 1-3 sentences of plain prose describing what users reported, common patterns, and rough counts (e.g. "three users mentioned…"). No bullets, no markdown.
    Combine similar issues into the same section instead of repeating them. Be specific and factual; avoid speculation and filler.
    Always respond in the requested target language.
    """
    private let translationInstructions = """
    You are a translator. Translate the user's text into the requested target language.
    Preserve meaning, tone, and any URLs, code identifiers, or @mentions verbatim.

    Return a structured result:
      • didTranslate: true only when you produced a real translation in the target language. Set to false for anything else — including when the input is a single letter, a symbol, already in the target language, untranslatable, or you would otherwise need to apologize or explain.
      • translation: the translated text only. No preamble, no quotation marks, no apologies, no explanations, no notes about the input. If didTranslate is false, leave translation empty.

    Never explain why you could not translate. Either translate, or set didTranslate to false with an empty translation.
    """

    #if canImport(FoundationModels)
    @ObservationIgnored
    @available(macOS 26, iOS 26, *)
    private var summarySession: LanguageModelSession? {
        get { _summarySession as? LanguageModelSession }
        set { _summarySession = newValue }
    }
    @ObservationIgnored
    private var _summarySession: Any?
    #endif

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

    nonisolated func summarize(issues: [FeedbackIssue], targetLanguage: String) async throws -> IssueSummaryDTO {
        try await MainActor.run { try checkAvailable() }
        #if canImport(FoundationModels)
        if #available(macOS 26, iOS 26, *) {
            return try await runSummarize(issues: issues, targetLanguage: targetLanguage)
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
    fileprivate func runSummarize(issues: [FeedbackIssue], targetLanguage: String) async throws -> IssueSummaryDTO {
        guard !issues.isEmpty else { throw IntelligenceError.empty }
        let session = await MainActor.run { () -> LanguageModelSession in
            if let cached = self.summarySession { return cached }
            let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
            let s = LanguageModelSession(model: model, instructions: self.summaryInstructions)
            self.summarySession = s
            return s
        }
        let prompt = SummaryPromptBuilder.build(issues: issues, targetLanguage: targetLanguage)
        do {
            let response = try await session.respond(to: prompt, generating: IssueSummary.self)
            return IssueSummaryDTO(response.content)
        } catch let error as LanguageModelSession.GenerationError {
            if case .guardrailViolation = error {
                return IssueSummaryDTO(
                    headline: "\(issues.count) unread issues",
                    sections: []
                )
            }
            throw error
        }
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
