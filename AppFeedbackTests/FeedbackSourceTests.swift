import XCTest
@testable import AppFeedback

final class FeedbackSourceTests: XCTestCase {
    func test_rawValues_match_contract() {
        XCTAssertEqual(FeedbackSource.sdk.rawValue, "sdk")
        XCTAssertEqual(FeedbackSource.appStore.rawValue, "app-store")
        XCTAssertEqual(FeedbackSource.email.rawValue, "email")
    }

    func test_allCases_order() {
        XCTAssertEqual(FeedbackSource.allCases, [.sdk, .appStore, .email])
    }

    func test_displayNames() {
        XCTAssertEqual(FeedbackSource.sdk.displayName, "SDK")
        XCTAssertEqual(FeedbackSource.appStore.displayName, "App Store")
        XCTAssertEqual(FeedbackSource.email.displayName, "Email")
    }

    func test_github_label_mapping() {
        XCTAssertNil(FeedbackSource.sdk.githubLabel)          // SDK is implicit; no label
        XCTAssertEqual(FeedbackSource.appStore.githubLabel, "source:app-store")
        XCTAssertEqual(FeedbackSource.email.githubLabel, "source:email")
    }

    func test_from_label() {
        XCTAssertEqual(FeedbackSource.from(label: "source:app-store"), .appStore)
        XCTAssertEqual(FeedbackSource.from(label: "source:email"), .email)
        XCTAssertNil(FeedbackSource.from(label: "rating:5"))
        XCTAssertNil(FeedbackSource.from(label: "user-submitted"))
    }

    func test_symbols_are_nonempty() {
        for source in FeedbackSource.allCases {
            XCTAssertFalse(source.systemImageName.isEmpty)
        }
    }
}
