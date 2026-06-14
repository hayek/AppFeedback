import Foundation
import Observation

@Observable @MainActor
final class IntelligenceSettings {
    private let defaults: UserDefaults
    private static let translationEnabledKey = "intelligence.translationEnabled"
    private static let targetLanguageKey = "intelligence.targetLanguage"
    private static let summariesEnabledKey = "intelligence.summariesEnabled"

    var translationEnabled: Bool {
        didSet { defaults.set(translationEnabled, forKey: Self.translationEnabledKey) }
    }
    var targetLanguageCode: String {
        didSet { defaults.set(targetLanguageCode, forKey: Self.targetLanguageKey) }
    }
    var summariesEnabled: Bool {
        didSet { defaults.set(summariesEnabled, forKey: Self.summariesEnabledKey) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.translationEnabled = (defaults.object(forKey: Self.translationEnabledKey) as? Bool) ?? true
        self.summariesEnabled = (defaults.object(forKey: Self.summariesEnabledKey) as? Bool) ?? true
        let storedLanguage = defaults.string(forKey: Self.targetLanguageKey) ?? ""
        self.targetLanguageCode = storedLanguage.isEmpty ? Self.systemLanguageCode() : storedLanguage
    }

    /// Languages offered as translation targets. Apple's Translation framework supports
    /// these and downloads each language pair on demand the first time it's used — no
    /// Apple Intelligence required. Keep in sync with `pickerOptions`.
    static let supportedTargetLanguageCodes: Set<String> = [
        "en", "ar", "zh-Hans", "zh-Hant", "nl", "fr", "de", "hi", "id", "it",
        "ja", "ko", "pl", "pt", "ru", "es", "th", "tr", "uk", "vi"
    ]

    /// The user's preferred language if it's an available translation target, otherwise English.
    static func systemLanguageCode() -> String {
        for preferred in Locale.preferredLanguages {
            let locale = Locale(identifier: preferred)
            if let script = locale.language.script?.identifier,
               let base = locale.language.languageCode?.identifier {
                let scripted = "\(base)-\(script)"
                if supportedTargetLanguageCodes.contains(scripted) { return scripted }
            }
            if let base = locale.language.languageCode?.identifier,
               supportedTargetLanguageCodes.contains(base) {
                return base
            }
        }
        return "en"
    }

    /// Target-language options, ordered alphabetically by display name after English.
    static let pickerOptions: [(code: String, displayName: String)] = [
        ("en", "English"),
        ("ar", "Arabic"),
        ("zh-Hans", "Chinese (Simplified)"),
        ("zh-Hant", "Chinese (Traditional)"),
        ("nl", "Dutch"),
        ("fr", "French"),
        ("de", "German"),
        ("hi", "Hindi"),
        ("id", "Indonesian"),
        ("it", "Italian"),
        ("ja", "Japanese"),
        ("ko", "Korean"),
        ("pl", "Polish"),
        ("pt", "Portuguese"),
        ("ru", "Russian"),
        ("es", "Spanish"),
        ("th", "Thai"),
        ("tr", "Turkish"),
        ("uk", "Ukrainian"),
        ("vi", "Vietnamese")
    ]
}
