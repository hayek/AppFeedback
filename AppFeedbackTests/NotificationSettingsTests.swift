import XCTest
@testable import AppFeedback

final class NotificationSettingsTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suiteName = "NotificationSettingsTests"

    override func setUp() {
        super.setUp()
        UserDefaults().removePersistentDomain(forName: suiteName)
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func test_default_isDisabledAndNotPrompted() {
        let s = NotificationSettings(defaults: defaults)
        XCTAssertFalse(s.isEnabled)
        XCTAssertFalse(s.hasRequestedAuthorization)
    }

    func test_setIsEnabled_persists() {
        NotificationSettings(defaults: defaults).isEnabled = true
        XCTAssertTrue(NotificationSettings(defaults: defaults).isEnabled)
    }

    func test_setHasRequestedAuthorization_persists() {
        NotificationSettings(defaults: defaults).hasRequestedAuthorization = true
        XCTAssertTrue(NotificationSettings(defaults: defaults).hasRequestedAuthorization)
    }
}
