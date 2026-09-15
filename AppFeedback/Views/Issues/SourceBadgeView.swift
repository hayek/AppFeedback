import SwiftUI

/// Pure presentation rules for the source badge — extracted so they're unit-testable
/// without rendering SwiftUI (which isn't unit-testable in this target).
enum SourceBadge {
    /// Number of filled stars to draw (App Store ratings are 1…5, clamped).
    static func filledStars(rating: Int?) -> Int {
        guard let rating else { return 0 }
        return max(0, min(5, rating))
    }

    /// Stars are shown only for App Store items that carry a rating.
    static func showsStars(source: FeedbackSource, rating: Int?) -> Bool {
        source == .appStore && rating != nil
    }

    /// Localized country name for an App Store storefront code (ASC sends ISO-3166 alpha-3, which
    /// `Locale` resolves directly). Falls back to the raw code for unknown territories; nil when
    /// the item isn't an App Store review or carries no territory.
    static func countryName(source: FeedbackSource, territory: String?, locale: Locale = .current) -> String? {
        guard source == .appStore,
              let code = territory?.trimmingCharacters(in: .whitespaces), !code.isEmpty else { return nil }
        return locale.localizedString(forRegionCode: code) ?? code
    }
}

/// Leading badge on a feedback row showing its source: App Store (Apple mark + an
/// inline 5-star rating), Email (envelope), or SDK (wrench). Derived purely from
/// `FeedbackIssue.source`/`rating`; falls back to SDK when source is `.sdk`.
struct SourceBadgeView: View {
    let source: FeedbackSource
    let rating: Int?
    var territory: String? = nil

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: source.systemImageName)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .accessibilityLabel(source.displayName)
            if SourceBadge.showsStars(source: source, rating: rating) {
                starRow
            }
            if let country = SourceBadge.countryName(source: source, territory: territory) {
                Text(country)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.secondary.opacity(0.10), in: Capsule())
        .overlay(Capsule().stroke(Color.secondary.opacity(0.18), lineWidth: 0.5))
    }

    private var starRow: some View {
        let filled = SourceBadge.filledStars(rating: rating)
        return HStack(spacing: 1) {
            ForEach(0..<5, id: \.self) { index in
                Image(systemName: index < filled ? "star.fill" : "star")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(index < filled ? AnyShapeStyle(Color.yellow) : AnyShapeStyle(HierarchicalShapeStyle.tertiary))
            }
        }
        .accessibilityLabel("\(filled) of 5 stars")
    }
}
