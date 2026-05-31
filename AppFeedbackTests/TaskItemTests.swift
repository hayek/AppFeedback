import XCTest
@testable import AppFeedback

final class TaskItemTests: XCTestCase {
    private func issue(number: Int, body: String, labels: [String], state: IssueState, milestone: String?) -> FeedbackIssue {
        FeedbackIssue(
            number: number, title: "T\(number)", createdAt: Date(), rawBody: body,
            appName: nil, appVersion: nil, device: nil, osVersion: nil, email: nil,
            description: body, labels: labels.map { IssueLabel(name: $0, colorHex: "ededed") },
            state: state, milestoneTitle: milestone
        )
    }

    func testParsesStatusPriorityAndRefs() {
        let body = FeedbackTaskRefParser.upsert(into: "Do it", refs: [12, 15])
        let item = TaskItem(issue: issue(
            number: 99, body: body,
            labels: [AppFeedbackLabels.task, "status:in-progress", "priority:high"],
            state: .open, milestone: "1.2.0"
        ))
        XCTAssertEqual(item.number, 99)
        XCTAssertEqual(item.feedbackRefs, [12, 15])
        XCTAssertEqual(item.status, .inProgress)
        XCTAssertEqual(item.priority, .high)
        XCTAssertEqual(item.milestoneTitle, "1.2.0")
        XCTAssertFalse(item.isClosed)
    }

    func testClosedIssueIsDoneEquivalent() {
        let item = TaskItem(issue: issue(number: 1, body: "", labels: [AppFeedbackLabels.task], state: .closed, milestone: nil))
        XCTAssertTrue(item.isClosed)
        XCTAssertTrue(item.isCompleted)   // closed OR status:done
    }
}
