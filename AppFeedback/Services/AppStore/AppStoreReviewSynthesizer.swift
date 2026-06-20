import Foundation
import CryptoKit

/// Pure rendering of an App Store review into the GitHub-issue title/body/labels that the rest of
/// the app understands. The body carries the Phase-1 source markers verbatim so origin survives the
/// GitHub round-trip back into the parser. No I/O — fully unit-testable.
enum AppStoreReviewSynthesizer {
    static let reviewDeletedLabel = "review-deleted"

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func title(for review: ASCReview) -> String {
        if let t = review.title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { return t }
        return "\(stars(review.rating)) review (\(review.territory))"
    }

    /// Inline-star glyph used in the fallback title.
    private static func stars(_ rating: Int) -> String {
        let r = max(0, min(5, rating))
        return String(repeating: "★", count: r) + String(repeating: "☆", count: 5 - r)
    }

    static func labels(for review: ASCReview) -> [String] {
        ["source:app-store", "rating:\(max(1, min(5, review.rating)))"]
    }

    static func body(for review: ASCReview) -> String {
        var lines: [String] = []
        lines.append(review.body?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
        lines.append("")
        lines.append("---")
        lines.append("source: app-store")
        lines.append("rating: \(review.rating)")
        if let nick = review.reviewerNickname, !nick.isEmpty { lines.append("reviewerNickname: \(nick)") }
        lines.append("territory: \(review.territory)")
        lines.append("reviewId: \(review.id)")
        lines.append("reviewCreatedAt: \(iso.string(from: review.createdDate))")
        return lines.joined(separator: "\n")
    }

    /// SHA-256 hex of normalized `rating + "\n" + title + "\n" + body`. Detects edits since the ASC
    /// API exposes no `updatedDate` on reviews.
    static func contentHash(for review: ASCReview) -> String {
        let normalized = "\(review.rating)\n\(review.title ?? "")\n\(review.body ?? "")"
        let digest = SHA256.hash(data: Data(normalized.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func editedNote(at date: Date) -> String {
        "_Review edited \(iso.string(from: date))_"
    }
}
