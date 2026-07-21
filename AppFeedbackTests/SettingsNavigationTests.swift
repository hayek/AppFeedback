import Testing
import Foundation
@testable import AppFeedback

@MainActor
struct SettingsNavigationTests {
    @Test func focusSelectsProduct() {
        let nav = SettingsNavigation()
        let id = UUID()
        nav.focus(productID: id)
        #expect(nav.selection == .product(id))
    }

    @Test func normalizedKeepsValidProductSelection() {
        let nav = SettingsNavigation()
        let id = UUID()
        nav.selection = .product(id)
        #expect(nav.normalizedSelection(productIDs: [id, UUID()]) == .product(id))
    }

    @Test func normalizedKeepsNonProductSelections() {
        let nav = SettingsNavigation()
        for sel in [SettingsSelection.email, .intelligence, .notifications] {
            nav.selection = sel
            #expect(nav.normalizedSelection(productIDs: []) == sel)
        }
    }

    @Test func missingProductFallsBackToFirstProduct() {
        let nav = SettingsNavigation()
        let first = UUID()
        nav.selection = .product(UUID())   // deleted product
        #expect(nav.normalizedSelection(productIDs: [first]) == .product(first))
    }

    @Test func nilSelectionFallsBackToFirstProductThenEmail() {
        let nav = SettingsNavigation()
        let first = UUID()
        #expect(nav.normalizedSelection(productIDs: [first]) == .product(first))
        #expect(nav.normalizedSelection(productIDs: []) == .email)
    }

    @Test func missingProductWithNoProductsFallsBackToEmail() {
        let nav = SettingsNavigation()
        nav.selection = .product(UUID())
        #expect(nav.normalizedSelection(productIDs: []) == .email)
    }
}
