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

    // MARK: - displayStatus

    func testDisplayStatusReflectsRawStatusWhenOpen() {
        let todo = TaskItem(issue: issue(number: 1, body: "", labels: [AppFeedbackLabels.task], state: .open, milestone: nil))
        XCTAssertEqual(todo.displayStatus, .todo)
        let wip = TaskItem(issue: issue(number: 2, body: "", labels: [AppFeedbackLabels.task, "status:in-progress"], state: .open, milestone: nil))
        XCTAssertEqual(wip.displayStatus, .inProgress)
        let done = TaskItem(issue: issue(number: 3, body: "", labels: [AppFeedbackLabels.task, "status:done"], state: .open, milestone: nil))
        XCTAssertEqual(done.displayStatus, .done)
    }

    func testDisplayStatusIsDoneWhenClosedEvenIfLabeledTodo() {
        // A closed issue still carries its old status:todo label, but reads as Done.
        let item = TaskItem(issue: issue(number: 1, body: "", labels: [AppFeedbackLabels.task, "status:todo"], state: .closed, milestone: nil))
        XCTAssertEqual(item.status, .todo)
        XCTAssertEqual(item.displayStatus, .done)
    }

    // MARK: - matchesSearch

    func testMatchesSearchTitleNumberAndProse() {
        let body = FeedbackTaskRefParser.upsert(into: "investigate the crash log", refs: [7])
        let item = TaskItem(issue: issue(number: 42, body: body, labels: [AppFeedbackLabels.task], state: .open, milestone: nil))
        XCTAssertTrue(item.matchesSearch("T42"))          // title is "T42"
        XCTAssertTrue(item.matchesSearch("#42"))          // issue number
        XCTAssertTrue(item.matchesSearch("CRASH"))        // prose, case-insensitive
        XCTAssertFalse(item.matchesSearch("nonexistent"))   // matches no field
        XCTAssertFalse(item.matchesSearch("#4"))            // exact-number: must not match #42
    }

    func testMatchesSearchIgnoresRefBlockAndBlankQuery() {
        let body = FeedbackTaskRefParser.upsert(into: "notes", refs: [55])
        let item = TaskItem(issue: issue(number: 1, body: body, labels: [AppFeedbackLabels.task], state: .open, milestone: nil))
        XCTAssertFalse(item.matchesSearch("Addresses"))   // lives only in the stripped ref block
        XCTAssertFalse(item.matchesSearch("#55"))         // ref number is in the block, not prose; not this task's number
        XCTAssertTrue(item.matchesSearch("   "))          // blank query matches everything
    }
}
