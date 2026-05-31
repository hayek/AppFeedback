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

    private func todoTask(_ number: Int, milestone: String? = nil) -> TaskItem {
        TaskItem(issue: FeedbackIssue(number: number, title: "t\(number)", createdAt: Date(), rawBody: "",
            appName: nil, appVersion: nil, device: nil, osVersion: nil, email: nil, description: "",
            labels: [IssueLabel(name: AppFeedbackLabels.task, colorHex: "x")], state: .open, milestoneTitle: milestone))
    }

    func testApplyOptimisticUpdatesStatusAndPriorityAndReturnsPrevious() {
        let model = ProjectInspectorModel()
        model.setTasks([todoTask(1)])                    // status .todo, priority .med
        let previous = model.applyOptimistic(number: 1, status: .inProgress, priority: .high)
        XCTAssertEqual(model.tasks.first?.status, .inProgress)
        XCTAssertEqual(model.tasks.first?.priority, .high)
        XCTAssertEqual(previous?.status, .todo)
        XCTAssertEqual(previous?.priority, .med)
    }

    func testRestoreRollsBackOptimisticUpdate() {
        let model = ProjectInspectorModel()
        model.setTasks([todoTask(1)])
        let previous = model.applyOptimistic(number: 1, status: .done)
        XCTAssertEqual(model.tasks.first?.status, .done)
        XCTAssertTrue(model.tasks.first?.isCompleted ?? false)   // done ⇒ completed
        model.restore(previous!)
        XCTAssertEqual(model.tasks.first?.status, .todo)
        XCTAssertFalse(model.tasks.first?.isCompleted ?? true)
    }

    func testApplyOptimisticUnknownNumberIsNoOp() {
        let model = ProjectInspectorModel()
        model.setTasks([todoTask(1)])
        XCTAssertNil(model.applyOptimistic(number: 999, status: .done))
        XCTAssertEqual(model.tasks.first?.status, .todo)
    }
}
