import Foundation
import Observation

@Observable
final class NotificationSettings {
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let enabledKey = "appfeedback.notifications.isEnabled"
    @ObservationIgnored private let promptedKey = "appfeedback.notifications.hasRequestedAuthorization"

    var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: enabledKey) }
    }
    var hasRequestedAuthorization: Bool {
        didSet { defaults.set(hasRequestedAuthorization, forKey: promptedKey) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.isEnabled = defaults.bool(forKey: enabledKey)
        self.hasRequestedAuthorization = defaults.bool(forKey: promptedKey)
    }
}
