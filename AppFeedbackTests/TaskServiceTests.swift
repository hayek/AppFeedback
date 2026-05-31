import XCTest
@testable import AppFeedback

final class TaskServiceTests: XCTestCase {
    func testLabelAssembly() {
        let labels = TaskService.labels(status: .inProgress, priority: .high)
        XCTAssertTrue(labels.contains(AppFeedbackLabels.task))
        XCTAssertTrue(labels.contains("status:in-progress"))
        XCTAssertTrue(labels.contains("priority:high"))
        XCTAssertEqual(labels.count, 3)
    }

    func testBodyWithRefs() {
        let body = TaskService.body(prose: "Fix it", feedbackRefs: [15, 12])
        XCTAssertEqual(FeedbackTaskRefParser.parse(body), [12, 15])
    }
}
