import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

#if canImport(FoundationModels)
@available(macOS 26, iOS 26, *)
@Generable
struct TranslationResult: Equatable, Sendable {
    @Guide(description: "True only when the translation field contains a real translation in the target language. False for unsupported, untranslatable, or already-in-target inputs.")
    var didTranslate: Bool

    @Guide(description: "The translated text only. No preamble, quotation marks, apologies, or explanations. Empty when didTranslate is false.")
    var translation: String
}

@available(macOS 26, iOS 26, *)
@Generable
struct IssueSummary: Equatable, Sendable {
    @Guide(description: "One headline sentence on overall feedback tone and focus for this period.")
    var headline: String

    @Guide(description: "2-4 concise sentences of factual prose naming what delighted users or worked well — praise, stable areas, positives. Mention rough frequencies when clear. Plain sentences only.")
    var pros: String

    @Guide(description: "2-4 concise sentences of factual prose naming problems — bugs, regressions, pain points, frustrations. Mention rough frequencies when clear. Plain sentences only.")
    var cons: String
}
#endif

/// Plain-Swift mirror used by views and tests so they don't need FoundationModels.
struct IssueSummaryDTO: Equatable, Sendable {
    var headline: String
    var pros: String
    var cons: String
}

#if canImport(FoundationModels)
@available(macOS 26, iOS 26, *)
extension IssueSummaryDTO {
    init(_ summary: IssueSummary) {
        self.headline = summary.headline
        self.pros = summary.pros
        self.cons = summary.cons
    }
}
#endif
