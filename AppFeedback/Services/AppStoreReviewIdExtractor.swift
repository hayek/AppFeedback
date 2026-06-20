import Foundation

/// Pulls the App Store `reviewId` out of a synthesized feedback body. Phase 3 writes the
/// review's id as a `reviewId: <value>` marker line (same `key: value` grain the SDK uses
/// for `App:` / `App Version:`); the write-back panel needs it to target the right review.
enum AppStoreReviewIdExtractor {
    /// The marker key, matching the Phase-1 BodyMarkers vocabulary entry "reviewId".
    private static let markerKey = "reviewId:"

    static func reviewId(fromBody body: String) -> String? {
        for rawLine in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix(markerKey) else { continue }
            let value = line.dropFirst(markerKey.count).trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        return nil
    }
}
