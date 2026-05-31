import XCTest
import SwiftUI
@testable import AppFeedback

@MainActor
final class VersionsSectionSmokeTests: XCTestCase {
    func testVersionCardRendersWithoutCrash() {
        let view = VersionCard(name: "1.0.0", state: .wip, taskCount: 3, action: {})
        #if os(macOS)
        XCTAssertNotNil(NSHostingView(rootView: view))
        #else
        XCTAssertNotNil(view)
        #endif
    }
}
