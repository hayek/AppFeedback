import XCTest
@testable import AppFeedback

final class ColorPaletteTests: XCTestCase {

    func test_color_isSameForSameAppInSameList() {
        let apps = ["Alpha", "Beta", "Gamma"]
        let c1 = ColorPalette.color(for: "Beta", in: apps)
        let c2 = ColorPalette.color(for: "Beta", in: apps)
        XCTAssertEqual(c1, c2)
    }

    func test_color_differsBetweenApps() {
        let apps = ["Alpha", "Beta"]
        XCTAssertNotEqual(
            ColorPalette.color(for: "Alpha", in: apps),
            ColorPalette.color(for: "Beta", in: apps)
        )
    }

    func test_color_isSortOrderDeterministic() {
        let apps1 = ["Zeta", "Alpha"]
        let apps2 = ["Alpha", "Zeta"]
        XCTAssertEqual(
            ColorPalette.color(for: "Alpha", in: apps1),
            ColorPalette.color(for: "Alpha", in: apps2)
        )
    }

    func test_color_unknownApp_returnsDefaultColor() {
        let result = ColorPalette.color(for: "Unknown", in: [])
        XCTAssertNotNil(result)
    }
}
