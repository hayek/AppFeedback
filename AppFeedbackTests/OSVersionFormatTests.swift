import XCTest
@testable import AppFeedback

final class OSVersionFormatTests: XCTestCase {

    func testBuildAndVersionStripped() {
        XCTAssertEqual(OSVersionFormat.display("26.4 (Build 23EB45)"), "v26.4(23EB45)")
    }

    func testVersionPrefixStripped() {
        XCTAssertEqual(OSVersionFormat.display("Version 26.4 (Build 23EB45)"), "v26.4(23EB45)")
    }

    func testSpanishLocale() {
        XCTAssertEqual(OSVersionFormat.display("Versión 26.4 (Compilación 23EB45)"), "v26.4(23EB45)")
    }

    func testJapaneseLocale() {
        XCTAssertEqual(OSVersionFormat.display("バージョン 17.5 (ビルド 21F79)"), "v17.5(21F79)")
    }

    func testVersionOnly() {
        XCTAssertEqual(OSVersionFormat.display("17.5"), "v17.5")
    }

    func testEmptyString() {
        XCTAssertEqual(OSVersionFormat.display(""), "")
    }

    func testUnparseable() {
        XCTAssertEqual(OSVersionFormat.display("weird text"), "weird text")
    }
}
