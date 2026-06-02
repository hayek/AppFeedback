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

    func testVersionCardRendersWithCreationBadgeInEachPhase() {
        let phases: [CreationPhase] = [.creating, .created, .failed("no token")]
        for phase in phases {
            let view = VersionCard(name: "1.2.0", state: .new, taskCount: 0,
                                   creationBadge: phase, onRetry: {}, onDismiss: {}, action: {})
            #if os(macOS)
            XCTAssertNotNil(NSHostingView(rootView: view))
            #else
            XCTAssertNotNil(view)
            #endif
        }
    }
}
