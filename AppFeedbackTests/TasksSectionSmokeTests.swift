import XCTest
import SwiftUI
@testable import AppFeedback

@MainActor
final class TasksSectionSmokeTests: XCTestCase {
    func testTaskCardRendersWithoutCrash() {
        let task = TaskItem(issue: FeedbackIssue(number: 1, title: "t", createdAt: Date(),
            rawBody: "", appName: nil, appVersion: nil, device: nil, osVersion: nil, email: nil,
            description: "", labels: [IssueLabel(name: AppFeedbackLabels.task, colorHex: "5319e7")]))
        let view = TaskCard(task: task, onStatus: { _ in }, onPriority: { _ in }, onOpen: {})
        #if os(macOS)
        XCTAssertNotNil(NSHostingView(rootView: view))
        #else
        XCTAssertNotNil(view)
        #endif
    }
}
