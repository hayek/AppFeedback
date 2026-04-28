import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

#if canImport(FoundationModels)
@available(macOS 26, iOS 26, *)
@Generable
struct IssueSummary: Equatable, Sendable {
    @Guide(description: "A 1-sentence headline summarizing the unread issues")
    var headline: String

    @Guide(description: "3-5 themed bullets, each grouping related issues")
    var bullets: [Bullet]

    @Generable
    struct Bullet: Equatable, Sendable {
        @Guide(description: "Short description of the theme")
        var text: String

        @Guide(description: "How many of the unread issues fall under this theme")
        var issueCount: Int
    }
}
#endif

/// Plain-Swift mirror used by views and tests so they don't need FoundationModels.
struct IssueSummaryDTO: Equatable, Sendable {
    var headline: String
    var bullets: [Bullet]

    struct Bullet: Equatable, Sendable {
        var text: String
        var issueCount: Int
    }
}

#if canImport(FoundationModels)
@available(macOS 26, iOS 26, *)
extension IssueSummaryDTO {
    init(_ summary: IssueSummary) {
        self.headline = summary.headline
        self.bullets = summary.bullets.map { Bullet(text: $0.text, issueCount: $0.issueCount) }
    }
}
#endif
