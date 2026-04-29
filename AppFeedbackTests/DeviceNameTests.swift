import XCTest
@testable import AppFeedback

@MainActor
final class DeviceNameTests: XCTestCase {

    // Substring checks rather than exact strings: the catalog is sourced from
    // AppleDB at build time, so the marketing wording can drift between runs.

    func testMacBookProM3() {
        XCTAssertTrue(DeviceName.friendly("Mac15,3").contains("MacBook Pro"))
    }

    func testMacBookAirM2() {
        XCTAssertTrue(DeviceName.friendly("Mac14,15").contains("MacBook Air"))
    }

    func testMacStudio() {
        XCTAssertTrue(DeviceName.friendly("Mac14,14").contains("Mac Studio"))
    }

    func testIPhone15Pro() {
        XCTAssertTrue(DeviceName.friendly("iPhone16,1").contains("iPhone 15 Pro"))
    }

    func testIPadPro() {
        XCTAssertTrue(DeviceName.friendly("iPad14,5").contains("iPad Pro"))
    }

    func testAppleWatch() {
        XCTAssertTrue(DeviceName.friendly("Watch7,1").contains("Apple Watch"))
    }

    func testAppleTV() {
        XCTAssertTrue(DeviceName.friendly("AppleTV14,1").contains("Apple TV"))
    }

    func testHomePod() {
        XCTAssertTrue(DeviceName.friendly("AudioAccessory6,1").contains("HomePod"))
    }

    func testVisionPro() {
        XCTAssertTrue(DeviceName.friendly("RealityDevice14,1").contains("Vision Pro"))
    }

    func testMacBookNeo() {
        XCTAssertTrue(DeviceName.friendly("Mac17,5").contains("MacBook Neo"))
    }

    func testUnknownIdentifierFallsBack() {
        XCTAssertEqual(DeviceName.friendly("Banana42,1"), "Banana42,1")
    }

    func testEmptyString() {
        XCTAssertEqual(DeviceName.friendly(""), "")
    }

    func testWhitespaceOnly() {
        XCTAssertEqual(DeviceName.friendly("  "), "  ")
    }
}
