import XCTest
@testable import AppFeedback

final class DeviceNameTests: XCTestCase {

    func testMacBookProM3() {
        XCTAssertEqual(DeviceName.friendly("Mac15,3"), "MacBook Pro 14\" (M3, 2023)")
    }

    func testMacBookProM3Max16() {
        XCTAssertEqual(DeviceName.friendly("Mac15,9"), "MacBook Pro 16\" (M3 Max, 2023)")
    }

    func testMacStudioM2Ultra() {
        XCTAssertEqual(DeviceName.friendly("Mac14,14"), "Mac Studio (M2 Ultra, 2023)")
    }

    func testMacAir15M2() {
        XCTAssertEqual(DeviceName.friendly("Mac14,15"), "MacBook Air 15\" (M2, 2023)")
    }

    func testIPhone15Pro() {
        XCTAssertEqual(DeviceName.friendly("iPhone16,1"), "iPhone 15 Pro (2023)")
    }

    func testIPhone15ProMax() {
        XCTAssertEqual(DeviceName.friendly("iPhone16,2"), "iPhone 15 Pro Max (2023)")
    }

    func testIPadPro12_9Gen6() {
        XCTAssertEqual(DeviceName.friendly("iPad14,5"), "iPad Pro 12.9\" (6th gen, M2, 2022)")
    }

    func testAppleWatchSeries9() {
        XCTAssertEqual(DeviceName.friendly("Watch7,1"), "Apple Watch Series 9 (41mm GPS, 2023)")
    }

    func testAppleTV4K3rd() {
        XCTAssertEqual(DeviceName.friendly("AppleTV14,1"), "Apple TV 4K (3rd gen, 2022)")
    }

    func testHomePod2ndGen() {
        XCTAssertEqual(DeviceName.friendly("AudioAccessory6,1"), "HomePod (2nd gen, 2023)")
    }

    func testAppleVisionPro() {
        XCTAssertEqual(DeviceName.friendly("RealityDevice14,1"), "Apple Vision Pro (2024)")
    }

    func testUnknownIdentifier() {
        XCTAssertEqual(DeviceName.friendly("Banana42,1"), "Banana42,1")
    }

    func testEmptyString() {
        XCTAssertEqual(DeviceName.friendly(""), "")
    }

    func testWhitespaceOnly() {
        XCTAssertEqual(DeviceName.friendly("  "), "  ")
    }
}
