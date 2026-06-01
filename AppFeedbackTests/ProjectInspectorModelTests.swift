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

    func testApplyOptimisticMovesVersionAndCanClearIt() {
        let model = ProjectInspectorModel()
        model.setTasks([todoTask(1, milestone: "1.0")])
        model.applyOptimistic(number: 1, milestone: .some("2.0"))
        XCTAssertEqual(model.tasks.first?.milestoneTitle, "2.0")
        model.applyOptimistic(number: 1, milestone: .some(nil))   // .some(nil) clears the version
        XCTAssertNil(model.tasks.first?.milestoneTitle)
    }

    func testApplyOptimisticTitleAndNotesUpdate() {
        let model = ProjectInspectorModel()
        model.setTasks([todoTask(1)])
        model.applyOptimistic(number: 1, title: "Renamed", body: "new notes")
        XCTAssertEqual(model.tasks.first?.title, "Renamed")
        XCTAssertEqual(model.tasks.first?.body, "new notes")
    }

    func testApplyOptimisticReparsesFeedbackRefsFromBody() {
        let model = ProjectInspectorModel()
        model.setTasks([todoTask(1)])
        let body = FeedbackTaskRefParser.upsert(into: "notes", refs: [7, 9])
        model.applyOptimistic(number: 1, body: body)
        XCTAssertEqual(model.tasks.first?.feedbackRefs, [7, 9])
    }

    // Regression: attaching a second task to the same feedback used to vanish because the
    // post-write reload (inspector.setTasks) rebuilt tasks from GitHub read state that lags
    // the write, clobbering the optimistic ref edit. Pending overrides must survive a stale
    // reload and self-clear only once GitHub's returned refs actually match.
    func testPendingRefsSurviveStaleReloadForMultipleTasks() {
        let model = ProjectInspectorModel()
        let a = todoTask(1)
        let b = todoTask(2)
        model.setTasks([a, b])

        // Two drags onto feedback 100 — task 1, then task 2.
        _ = model.setPendingRefs(number: 1, refs: [100])
        _ = model.setPendingRefs(number: 2, refs: [100])
        XCTAssertEqual(model.task(number: 1)?.feedbackRefs, [100])
        XCTAssertEqual(model.task(number: 2)?.feedbackRefs, [100])

        // Stale reload (read replica hasn't caught up): both come back without the new ref.
        model.setTasks([a, b])
        XCTAssertEqual(model.task(number: 1)?.feedbackRefs, [100], "task 1 attach clobbered by stale reload")
        XCTAssertEqual(model.task(number: 2)?.feedbackRefs, [100], "task 2 attach clobbered by stale reload")

        // GitHub catches up for task 1 only: its override self-clears, task 2's persists.
        model.setTasks([a.withFeedbackRefs([100]), b])
        XCTAssertEqual(model.task(number: 1)?.feedbackRefs, [100])
        XCTAssertEqual(model.task(number: 2)?.feedbackRefs, [100])

        // GitHub catches up for task 2: a later reload now holds without any override.
        model.setTasks([a.withFeedbackRefs([100]), b.withFeedbackRefs([100])])
        XCTAssertEqual(model.task(number: 2)?.feedbackRefs, [100])
    }

    func testRevertPendingStopsOverridingAfterFailedWrite() {
        let model = ProjectInspectorModel()
        let a = todoTask(1)
        model.setTasks([a])
        let previous = model.setPendingRefs(number: 1, refs: [100])
        XCTAssertEqual(model.task(number: 1)?.feedbackRefs, [100])

        // Write failed → revert. A subsequent stale reload must NOT re-apply the override.
        model.revertPending(number: 1, to: previous!)
        XCTAssertEqual(model.task(number: 1)?.feedbackRefs, [])
        model.setTasks([a])
        XCTAssertEqual(model.task(number: 1)?.feedbackRefs, [])
    }

    func testDetachPendingOverrideSurvivesStaleReload() {
        let model = ProjectInspectorModel()
        let a = todoTask(1).withFeedbackRefs([100, 200])
        model.setTasks([a])
        // Detach feedback 100.
        _ = model.setPendingRefs(number: 1, refs: [200])
        XCTAssertEqual(model.task(number: 1)?.feedbackRefs, [200])
        // Stale reload still has both refs — the detach must survive.
        model.setTasks([a])
        XCTAssertEqual(model.task(number: 1)?.feedbackRefs, [200])
    }
}
