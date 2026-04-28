import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

@MainActor
@Observable
final class IntelligenceService: IntelligenceProvider {
    private(set) var availability: IntelligenceAvailability = .osTooOld
    private let summaryInstructions = """
    You are a concise product manager summarizing unread user feedback.
    Group related issues into 3-5 themes. Be specific, factual, and avoid speculation.
    Each bullet must include the count of issues that fall under its theme.
    Always respond in the requested target language.
    """
    private let translationInstructions = """
    You are a translator. Translate the user's text into the requested target language.
    Preserve meaning, tone, and any URLs, code identifiers, or @mentions verbatim.
    Output only the translated text — no preamble, no quotation marks.
    """

    #if canImport(FoundationModels)
    @ObservationIgnored
    @available(macOS 26, iOS 26, *)
    private var summarySession: LanguageModelSession? {
        get { _summarySession as? LanguageModelSession }
        set { _summarySession = newValue }
    }
    @ObservationIgnored
    @available(macOS 26, iOS 26, *)
    private var translationSession: LanguageModelSession? {
        get { _translationSession as? LanguageModelSession }
        set { _translationSession = newValue }
    }
    @ObservationIgnored
    private var _summarySession: Any?
    @ObservationIgnored
    private var _translationSession: Any?
    #endif

    init() {
        recomputeAvailability()
    }

    func recomputeAvailability() {
        #if canImport(FoundationModels)
        if #available(macOS 26, iOS 26, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                availability = .available
            case .unavailable(let reason):
                switch reason {
                case .appleIntelligenceNotEnabled: availability = .appleIntelligenceNotEnabled
                case .modelNotReady: availability = .modelNotReady
                case .deviceNotEligible: availability = .deviceNotEligible
                @unknown default: availability = .deviceNotEligible
                }
            @unknown default:
                availability = .deviceNotEligible
            }
        } else {
            availability = .osTooOld
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
        if availability != .available { throw IntelligenceError.unavailable }
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
        // Implemented in Task 8
        throw IntelligenceError.unavailable
    }
    fileprivate func runTranslate(text: String, from sourceCode: String?, to targetCode: String) async throws -> String {
        // Implemented in Task 9
        throw IntelligenceError.unavailable
    }
}
#endif
