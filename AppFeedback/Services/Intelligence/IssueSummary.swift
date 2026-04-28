import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

#if canImport(FoundationModels)
@available(macOS 26, iOS 26, *)
@Generable
struct IssueSummary: Equatable, Sendable {
    @Guide(description: "A 1-sentence headline summarizing all of the new feedback overall")
    var headline: String

    @Guide(description: "Per-theme sections. Combine similar issues into a single section and discuss them. Aim for 2-5 sections.")
    var sections: [Section]

    @Generable
    struct Section: Equatable, Sendable {
        @Guide(description: "Short title naming the theme (e.g. 'Login failures', 'Crash on launch')")
        var title: String

        @Guide(description: "1-3 sentences of plain prose describing this theme: what users reported, any common patterns, rough counts. No bullets or markdown.")
        var body: String
    }
}
#endif

/// Plain-Swift mirror used by views and tests so they don't need FoundationModels.
struct IssueSummaryDTO: Equatable, Sendable {
    var headline: String
    var sections: [Section]

    struct Section: Equatable, Sendable {
        var title: String
        var body: String
    }
}

#if canImport(FoundationModels)
@available(macOS 26, iOS 26, *)
extension IssueSummaryDTO {
    init(_ summary: IssueSummary) {
        self.headline = summary.headline
        self.sections = summary.sections.map { Section(title: $0.title, body: $0.body) }
    }
}
#endif
