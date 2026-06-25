import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

#if canImport(FoundationModels)
@available(macOS 26, iOS 26, *)
@Generable
struct IssueSummary: Equatable, Sendable {
    @Guide(description: "One headline sentence on overall feedback tone and focus for this period.")
    var headline: String

    @Guide(description: "Genuine praise only: things users explicitly liked, complimented, or reported as stable / working well. Plain sentences, no fixed length. If there is no real positive feedback this period, return an empty string. NEVER restate problems, bugs, regressions, frustrations, or feature requests here — those belong in `cons`.")
    var pros: String

    @Guide(description: "2-4 concise sentences of factual prose naming what needs attention — bugs, regressions, pain points, frustrations, plus unmet needs and feature requests. Mention rough frequencies when clear. Plain sentences only.")
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
