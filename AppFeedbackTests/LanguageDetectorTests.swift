import XCTest
@testable import AppFeedback

final class LanguageDetectorTests: XCTestCase {

    func test_detect_english() {
        let code = LanguageDetector.detect("The application keeps crashing when I open the settings page.")
        XCTAssertEqual(code, "en")
    }

    func test_detect_spanish() {
        let code = LanguageDetector.detect("La aplicación se cierra cuando abro la página de configuración.")
        XCTAssertEqual(code, "es")
    }

    func test_detect_japanese() {
        let code = LanguageDetector.detect("設定ページを開くとアプリがクラッシュします。")
        XCTAssertEqual(code, "ja")
    }

    func test_detect_emptyString_returnsNil() {
        XCTAssertNil(LanguageDetector.detect(""))
    }

    func test_detect_tooShort_returnsNil() {
        XCTAssertNil(LanguageDetector.detect("ok"))
    }
}
