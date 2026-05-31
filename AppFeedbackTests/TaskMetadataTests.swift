import XCTest
@testable import AppFeedback

final class TaskMetadataTests: XCTestCase {
    func testStatusFromLabels() {
        XCTAssertEqual(TaskStatus(labels: ["status:in-progress", "other"]), .inProgress)
        XCTAssertEqual(TaskStatus(labels: ["nope"]), .todo)             // default
        XCTAssertEqual(TaskStatus(labels: ["status:done"]), .done)
    }

    func testPriorityFromLabels() {
        XCTAssertEqual(TaskPriority(labels: ["priority:high"]), .high)
        XCTAssertEqual(TaskPriority(labels: []), .med)                  // default
    }

    func testLabelRoundTrip() {
        XCTAssertEqual(TaskStatus.done.label, "status:done")
        XCTAssertEqual(TaskPriority.low.label, "priority:low")
        XCTAssertEqual(AppFeedbackLabels.task, "appfeedback:task")
    }
}
