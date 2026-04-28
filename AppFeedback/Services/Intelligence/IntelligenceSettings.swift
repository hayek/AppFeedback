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

    /// Languages Apple Intelligence currently supports for on-device generation.
    /// Keep in sync with Apple's supported list.
    static let appleIntelligenceSupportedLanguageCodes: Set<String> = [
        "en", "fr", "de", "it", "ja", "ko", "pt", "es", "zh-Hans", "vi"
    ]

    /// The user's preferred language if Apple Intelligence supports it, otherwise English.
    static func systemLanguageCode() -> String {
        for preferred in Locale.preferredLanguages {
            let locale = Locale(identifier: preferred)
            if let script = locale.language.script?.identifier,
               let base = locale.language.languageCode?.identifier {
                let scripted = "\(base)-\(script)"
                if appleIntelligenceSupportedLanguageCodes.contains(scripted) { return scripted }
            }
            if let base = locale.language.languageCode?.identifier,
               appleIntelligenceSupportedLanguageCodes.contains(base) {
                return base
            }
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
