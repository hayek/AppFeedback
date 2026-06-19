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
