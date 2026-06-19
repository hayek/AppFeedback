import XCTest
@testable import AppFeedback

@MainActor
final class SettingsNavigationTests: XCTestCase {
    func test_defaultTab_isProducts() {
        let nav = SettingsNavigation()
        XCTAssertEqual(nav.selectedTab, .products)
    }

    func test_settingsTab_hasProductsCase_notRepos() {
        // .products replaces the old .repos; rawValue stays "products".
        XCTAssertEqual(SettingsTab(rawValue: "products"), .products)
        XCTAssertNil(SettingsTab(rawValue: "repos"))
    }
}

extension SettingsNavigationTests {
    func test_focus_setsTabAndProduct() {
        let nav = SettingsNavigation()
        let id = UUID()
        nav.selectedTab = .email          // start elsewhere
        nav.focus(productID: id)
        XCTAssertEqual(nav.selectedTab, .products)
        XCTAssertEqual(nav.selectedProductID, id)
    }

    func test_selectedProductID_defaultsNil() {
        XCTAssertNil(SettingsNavigation().selectedProductID)
    }
}
