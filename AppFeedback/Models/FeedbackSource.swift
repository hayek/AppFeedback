import Foundation

/// The origin of a feedback item. Survives the GitHub round-trip via the
/// `source-meta-v1` body marker (raw value) and, for non-SDK sources, a
/// `source:<rawValue>` label. SDK is the implicit default for any issue our
/// adapters did not synthesize.
enum FeedbackSource: String, Codable, CaseIterable, Sendable {
    case sdk = "sdk"
    case appStore = "app-store"
    case email = "email"

    var displayName: String {
        switch self {
        case .sdk: return "SDK"
        case .appStore: return "App Store"
        case .email: return "Email"
        }
    }

    /// SF Symbol shown in the filter menu and (for SDK/Email) the row badge.
    var systemImageName: String {
        switch self {
        case .sdk: return "wrench.and.screwdriver.fill"
        case .appStore: return "apple.logo"
        case .email: return "envelope.fill"
        }
    }

    /// GitHub label string for this source, or nil for `.sdk` (SDK is implicit —
    /// the absence of a `source:*` label / `source` marker means SDK).
    var githubLabel: String? {
        switch self {
        case .sdk: return nil
        case .appStore: return "source:app-store"
        case .email: return "source:email"
        }
    }

    /// Resolves a `source:<rawValue>` GitHub label back to a source, or nil if
    /// the label is not a source label.
    static func from(label: String) -> FeedbackSource? {
        guard label.hasPrefix("source:") else { return nil }
        return FeedbackSource(rawValue: String(label.dropFirst("source:".count)))
    }
}
