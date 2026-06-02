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

    func testPendingTaskCardRendersInEachPhase() {
        let draft = TaskDraft(title: "New task", prose: "", status: .todo, priority: .med,
                              milestoneNumber: nil, milestoneTitle: "1.0")
        let phases: [CreationPhase] = [.creating, .created, .failed("network error")]
        for phase in phases {
            let creation = TaskCreation(id: UUID(), sequence: 1, draft: draft, phase: phase,
                                        number: phase == .created ? 5 : nil)
            let view = PendingTaskCard(creation: creation, onRetry: {}, onDismiss: {})
            #if os(macOS)
            XCTAssertNotNil(NSHostingView(rootView: view))
            #else
            XCTAssertNotNil(view)
            #endif
        }
    }
}
