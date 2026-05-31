import XCTest
@testable import AppFeedback

final class ReleaseRecipientCalculatorTests: XCTestCase {
    private func fb(_ n: Int, _ email: String?) -> FeedbackIssue {
        FeedbackIssue(number: n, title: "f\(n)", createdAt: Date(), rawBody: "",
            appName: nil, appVersion: nil, device: nil, osVersion: nil, email: email,
            description: "", labels: [])
    }
    private func task(_ n: Int, refs: [Int], completed: Bool, version: String) -> TaskItem {
        let labels = [IssueLabel(name: AppFeedbackLabels.task, colorHex: "x")]
        let body = FeedbackTaskRefParser.upsert(into: "", refs: refs)
        return TaskItem(issue: FeedbackIssue(number: n, title: "t\(n)", createdAt: Date(), rawBody: body,
            appName: nil, appVersion: nil, device: nil, osVersion: nil, email: nil, description: "",
            labels: labels, state: completed ? .closed : .open, milestoneTitle: version))
    }

    func testDedupesByEmailAndOnlyCompletedTasks() {
        let tasks = [
            task(100, refs: [1, 2], completed: true, version: "1.2"),
            task(101, refs: [3],    completed: false, version: "1.2"),   // not completed → excluded
            task(102, refs: [2],    completed: true, version: "1.2"),
        ]
        let feedback = [fb(1, "alice@x.com"), fb(2, "alice@x.com"), fb(3, "bob@x.com"), fb(99, nil)]
        let recipients = ReleaseRecipientCalculator.recipients(versionNamed: "1.2", tasks: tasks, feedback: feedback)
        XCTAssertEqual(recipients.count, 1)                          // only alice; bob's task incomplete
        XCTAssertEqual(recipients.first?.email, "alice@x.com")
        XCTAssertEqual(recipients.first?.feedbackNumbers, [1, 2])    // deduped + sorted across her tasks
    }

    func testHidesFeedbackWithoutEmail() {
        let tasks = [task(100, refs: [99], completed: true, version: "1.2")]
        let recipients = ReleaseRecipientCalculator.recipients(versionNamed: "1.2", tasks: tasks, feedback: [fb(99, nil)])
        XCTAssertTrue(recipients.isEmpty)
    }
}
