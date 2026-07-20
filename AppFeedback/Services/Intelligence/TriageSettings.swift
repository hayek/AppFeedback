import Foundation
import Observation

/// How autonomously AI triage acts on new feedback.
enum TriageMode: String, CaseIterable, Sendable {
    case off
    /// Everything becomes a suggestion the user accepts or dismisses.
    case suggest
    /// Assigns to existing tasks auto-apply; new-task creates need confirmation.
    case hybrid
    /// Assigns and creates both auto-apply.
    case fullAuto

    var displayName: String {
        switch self {
        case .off: return "Off"
        case .suggest: return "Suggest only"
        case .hybrid: return "Auto-assign, confirm new tasks"
        case .fullAuto: return "Fully automatic"
        }
    }
}

@Observable @MainActor
final class TriageSettings {
    private let defaults: UserDefaults
    private static let modeKey = "triage.mode"
    private static let snapshotKeyPrefix = "triage.snapshotted."

    var mode: TriageMode {
        didSet { defaults.set(mode.rawValue, forKey: Self.modeKey) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.mode = defaults.string(forKey: Self.modeKey).flatMap(TriageMode.init(rawValue:)) ?? .off
    }

    /// Per-repo first-sighting marker: the first time triage sees a repo's loaded
    /// feedback, the existing backlog is snapshotted as preexisting instead of triaged.
    func hasSnapshotted(owner: String, repo: String) -> Bool {
        defaults.bool(forKey: Self.snapshotKeyPrefix + "\(owner)/\(repo)")
    }

    func markSnapshotted(owner: String, repo: String) {
        defaults.set(true, forKey: Self.snapshotKeyPrefix + "\(owner)/\(repo)")
    }
}
