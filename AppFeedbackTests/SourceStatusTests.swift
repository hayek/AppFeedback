import XCTest
@testable import AppFeedback

final class SourceStatusTests: XCTestCase {
    private func config(
        appStoreAppAppleID: String? = nil,
        feedbackInboxAccountID: UUID? = nil
    ) -> ProductConfig {
        ProductConfig(
            displayName: "T", owner: "o", repo: "r",
            appStoreIssuerID: nil, appStoreKeyID: nil,
            appStoreAppAppleID: appStoreAppAppleID,
            feedbackInboxAccountID: feedbackInboxAccountID
        )
    }

    func test_appStore_off_whenAppAppleIDNil() {
        XCTAssertEqual(config().appStoreSourceStatus, .off)
    }

    func test_appStore_configured_whenAppAppleIDSet() {
        XCTAssertEqual(config(appStoreAppAppleID: "123456").appStoreSourceStatus, .configured)
    }

    func test_email_off_whenInboxAccountNil() {
        XCTAssertEqual(config().emailSourceStatus, .off)
    }

    func test_email_configured_whenInboxAccountSet() {
        XCTAssertEqual(config(feedbackInboxAccountID: UUID()).emailSourceStatus, .configured)
    }
}
