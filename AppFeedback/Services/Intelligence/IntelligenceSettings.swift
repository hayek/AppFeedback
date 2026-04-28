import Foundation
import Observation

@Observable @MainActor
final class IntelligenceSettings {
    private let defaults: UserDefaults
    private static let translationEnabledKey = "intelligence.translationEnabled"
    private static let targetLanguageKey = "intelligence.targetLanguage"

    var translationEnabled: Bool {
        didSet { defaults.set(translationEnabled, forKey: Self.translationEnabledKey) }
    }
    var targetLanguageCode: String {
        didSet { defaults.set(targetLanguageCode, forKey: Self.targetLanguageKey) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.translationEnabled = (defaults.object(forKey: Self.translationEnabledKey) as? Bool) ?? true
        let storedLanguage = defaults.string(forKey: Self.targetLanguageKey) ?? ""
        self.targetLanguageCode = storedLanguage.isEmpty ? Self.systemLanguageCode() : storedLanguage
    }

    static func systemLanguageCode() -> String {
        if let code = Locale.current.language.languageCode?.identifier, !code.isEmpty {
            return code
        }
        return "en"
    }

    static let pickerOptions: [(code: String, displayName: String)] = [
        ("en", "English"),
        ("es", "Spanish"),
        ("fr", "French"),
        ("de", "German"),
        ("it", "Italian"),
        ("pt", "Portuguese"),
        ("ja", "Japanese"),
        ("ko", "Korean"),
        ("zh-Hans", "Chinese (Simplified)"),
        ("ar", "Arabic"),
        ("ru", "Russian"),
        ("nl", "Dutch")
    ]
}
