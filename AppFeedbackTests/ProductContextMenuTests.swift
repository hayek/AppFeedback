import XCTest
@testable import AppFeedback

final class ProductContextMenuTests: XCTestCase {
    func test_menu_exposesSettingsAsLeadingItem() {
        XCTAssertEqual(ProductContextMenuAction.ordered.first, .settings)
    }

    func test_menu_containsSettingsColorRemove() {
        XCTAssertEqual(Set(ProductContextMenuAction.ordered), [.settings, .color, .remove])
    }

    func test_settings_titleAndSymbol() {
        XCTAssertEqual(ProductContextMenuAction.settings.title, "Settings…")
        XCTAssertEqual(ProductContextMenuAction.settings.systemImage, "gearshape")
    }
}
