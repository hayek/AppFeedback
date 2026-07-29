import Foundation
import SwiftData

/// Cloud-synced rolling-30-day AI summary for one (repo, target language) tuple.
/// Devices without on-device Foundation Models (e.g. older iPhones/iPads) hydrate
/// from this row instead of recomputing locally. Only written when the rolling
/// summary completes with no filters active — per-device filtered views are
/// transient and not cached.
///
/// CloudKit constraint: every stored property must be optional or have a default.
@Model
final class IssueSummaryCache {
    var repoOwner: String = ""
    var repoName: String = ""
    var targetLanguage: String = ""
    var headline: String = ""
    var pros: String = ""
    var cons: String = ""
    /// Sorted, comma-separated list of issue numbers used to generate this summary.
    /// Compared on read to detect whether the cached content is up-to-date.
    var inputFingerprint: String = ""
    var updatedAt: Date = Date()

    init(
        repoOwner: String,
        repoName: String,
        targetLanguage: String,
        headline: String,
        pros: String,
        cons: String,
        inputFingerprint: String,
        updatedAt: Date = Date()
    ) {
        self.repoOwner = repoOwner
        self.repoName = repoName
        self.targetLanguage = targetLanguage
        self.headline = headline
        self.pros = pros
        self.cons = cons
        self.inputFingerprint = inputFingerprint
        self.updatedAt = updatedAt
    }
}
