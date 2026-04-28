import XCTest
@testable import AppFeedback

@MainActor
final class IntelligenceSettingsTests: XCTestCase {

    private func makeSettings(suite: String = UUID().uuidString) -> (IntelligenceSettings, UserDefaults) {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (IntelligenceSettings(defaults: defaults), defaults)
    }

    func test_defaults_translationEnabledTrue_targetIsSystem() {
        let (s, _) = makeSettings()
        XCTAssertTrue(s.translationEnabled)
        XCTAssertFalse(s.targetLanguageCode.isEmpty)
    }

    func test_setTargetLanguage_persistsInDefaults() {
        let (s, defaults) = makeSettings()
        s.targetLanguageCode = "fr"
        XCTAssertEqual(defaults.string(forKey: "intelligence.targetLanguage"), "fr")
    }

    func test_setTranslationEnabled_persistsInDefaults() {
        let (s, defaults) = makeSettings()
        s.translationEnabled = false
        XCTAssertEqual(defaults.bool(forKey: "intelligence.translationEnabled"), false)
        XCTAssertNotNil(defaults.object(forKey: "intelligence.translationEnabled"))
    }

    func test_init_loadsExistingValues() {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set("ja", forKey: "intelligence.targetLanguage")
        defaults.set(false, forKey: "intelligence.translationEnabled")
        let s = IntelligenceSettings(defaults: defaults)
        XCTAssertEqual(s.targetLanguageCode, "ja")
        XCTAssertFalse(s.translationEnabled)
    }
}
