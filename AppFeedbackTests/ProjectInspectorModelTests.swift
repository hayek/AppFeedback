import XCTest
@testable import AppFeedback

@MainActor
final class ProjectInspectorModelTests: XCTestCase {
    func testTasksForVersionAndStartedFlag() {
        let model = ProjectInspectorModel()
        let t1 = TaskItem(issue: FeedbackIssue(number: 1, title: "a", createdAt: Date(), rawBody: "",
            appName: nil, appVersion: nil, device: nil, osVersion: nil, email: nil, description: "",
            labels: [IssueLabel(name: AppFeedbackLabels.task, colorHex: "x"), IssueLabel(name: "status:in-progress", colorHex: "x")],
            state: .open, milestoneTitle: "1.0.0"))
        let t2 = TaskItem(issue: FeedbackIssue(number: 2, title: "b", createdAt: Date(), rawBody: "",
            appName: nil, appVersion: nil, device: nil, osVersion: nil, email: nil, description: "",
            labels: [IssueLabel(name: AppFeedbackLabels.task, colorHex: "x")],
            state: .open, milestoneTitle: nil))
        model.setTasks([t1, t2])
        XCTAssertEqual(model.tasks(forVersionNamed: "1.0.0").map(\.number), [1])
        XCTAssertTrue(model.anyTaskStarted(versionNamed: "1.0.0"))
        XCTAssertFalse(model.anyTaskStarted(versionNamed: "2.0.0"))
    }
}
