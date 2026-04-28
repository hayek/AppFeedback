import Foundation

enum IntelligenceAvailability: Equatable {
    case available
    case appleIntelligenceNotEnabled
    case modelNotReady
    case deviceNotEligible
    case osTooOld

    var isReady: Bool { self == .available }

    var statusText: String {
        switch self {
        case .available: return "Apple Intelligence ready"
        case .appleIntelligenceNotEnabled: return "Apple Intelligence not enabled"
        case .modelNotReady: return "Model downloading…"
        case .deviceNotEligible: return "Not supported on this device"
        case .osTooOld: return "Requires macOS 26 or later"
        }
    }

    var systemImageName: String {
        switch self {
        case .available: return "checkmark.circle.fill"
        case .modelNotReady: return "arrow.down.circle"
        case .appleIntelligenceNotEnabled, .deviceNotEligible, .osTooOld: return "exclamationmark.triangle.fill"
        }
    }
}
