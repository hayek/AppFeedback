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

    // MARK: - Optimistic task creation

    private func draft(_ title: String, status: TaskStatus = .todo, priority: TaskPriority = .med) -> TaskDraft {
        TaskDraft(title: title, prose: "", status: status, priority: priority,
                  milestoneNumber: nil, milestoneTitle: nil)
    }

    func testBeginCreationInsertsCreatingCardNewestFirst() {
        let model = ProjectInspectorModel()
        let first = model.beginCreation(draft("a"))
        let second = model.beginCreation(draft("b"))
        XCTAssertEqual(model.creations.map(\.id), [second, first])   // newest on top
        XCTAssertEqual(model.creations.first?.phase, .creating)
        // No number yet → both render as their own placeholder cards.
        XCTAssertEqual(model.pendingCreations(loadedTaskNumbers: []).count, 2)
    }

    func testCreationsCarryAscendingSequence() {
        let model = ProjectInspectorModel()
        let first = model.beginCreation(draft("a"))
        let second = model.beginCreation(draft("b"))
        let firstSeq = model.creations.first { $0.id == first }?.sequence ?? 0
        let secondSeq = model.creations.first { $0.id == second }?.sequence ?? 0
        // Placeholders sort by sequence, so an older creation stays above a newer one — matching
        // the ascending issue-number order they take once their real issues load (no reorder).
        XCTAssertLessThan(firstSeq, secondSeq)
    }

    func testCreationsSurviveSetTasksReload() {
        let model = ProjectInspectorModel()
        let id = model.beginCreation(draft("New"))
        // A reload landing mid-creation rebuilds `tasks` but must not drop the optimistic card.
        model.setTasks([todoTask(1)])
        XCTAssertEqual(model.creations.map(\.id), [id])
    }

    func testCreatedCreationBecomesBadgeOnReloadedTaskThenClears() {
        let model = ProjectInspectorModel()
        let id = model.beginCreation(draft("New"))
        model.markCreated(id: id, number: 42)
        XCTAssertEqual(model.creations.first?.phase, .created)
        // Before the reload: #42 isn't in `tasks`, so it renders as its own placeholder card
        // (the panel only queries creationBadge for tasks that are actually present).
        XCTAssertEqual(model.pendingCreations(loadedTaskNumbers: []).map(\.id), [id])

        // The refresh brings in the real issue #42: it's no longer a placeholder, and the real
        // card wears the "Created" badge instead.
        model.setTasks([todoTask(42)])
        XCTAssertTrue(model.pendingCreations(loadedTaskNumbers: [42]).isEmpty)
        XCTAssertEqual(model.creationBadge(forTaskNumber: 42), .created)

        // Badge clears → the real task stays, just without a badge.
        model.removeCreation(id: id)
        XCTAssertNil(model.creationBadge(forTaskNumber: 42))
        XCTAssertTrue(model.tasks.contains { $0.number == 42 })
        XCTAssertTrue(model.creations.isEmpty)
    }

    func testRemoveCreationForTaskNumberDropsBadge() {
        let model = ProjectInspectorModel()
        let id = model.beginCreation(draft("New"))
        model.markCreated(id: id, number: 7)
        model.setTasks([todoTask(7)])
        XCTAssertEqual(model.creationBadge(forTaskNumber: 7), .created)
        model.removeCreation(forTaskNumber: 7)   // e.g. the task was deleted mid-badge
        XCTAssertNil(model.creationBadge(forTaskNumber: 7))
        XCTAssertTrue(model.creations.isEmpty)
    }

    func testMarkFailedKeepsCardWithReasonAndNoNumber() {
        let model = ProjectInspectorModel()
        let id = model.beginCreation(draft("New"))
        model.markFailed(id: id, reason: "No GitHub token")
        XCTAssertEqual(model.creations.count, 1)
        XCTAssertEqual(model.creations.first?.phase, .failed("No GitHub token"))
        XCTAssertNil(model.creations.first?.number)
        // A failed card has no number, so it always renders as its own placeholder.
        XCTAssertEqual(model.pendingCreations(loadedTaskNumbers: [1, 2, 3]).map(\.id), [id])
    }

    func testRetryReturnsFailedCardToCreating() {
        let model = ProjectInspectorModel()
        let id = model.beginCreation(draft("New"))
        model.markFailed(id: id, reason: "boom")
        XCTAssertTrue(model.retryCreation(id: id))
        XCTAssertEqual(model.creations.first?.phase, .creating)
        XCTAssertNil(model.creations.first?.number)
    }

    // Guards the Retry double-tap: retrying anything not currently failed is a no-op, so a
    // second tap can't fire a second concurrent GitHub write.
    func testRetryIsNoOpUnlessFailed() {
        let model = ProjectInspectorModel()
        let id = model.beginCreation(draft("New"))
        XCTAssertFalse(model.retryCreation(id: id))          // .creating → ignored
        model.markCreated(id: id, number: 9)
        XCTAssertFalse(model.retryCreation(id: id))          // .created → ignored
        XCTAssertFalse(model.retryCreation(id: UUID()))      // unknown id → ignored
    }

    func testDraftForCreationRoundTrips() {
        let model = ProjectInspectorModel()
        let id = model.beginCreation(draft("Title", status: .inProgress, priority: .high))
        XCTAssertEqual(model.draft(forCreation: id)?.title, "Title")
        XCTAssertEqual(model.draft(forCreation: id)?.status, .inProgress)
        XCTAssertEqual(model.draft(forCreation: id)?.priority, .high)
        XCTAssertNil(model.draft(forCreation: UUID()))
    }

    func testRemoveAndClearCreations() {
        let model = ProjectInspectorModel()
        let id1 = model.beginCreation(draft("a"))
        _ = model.beginCreation(draft("b"))
        model.removeCreation(id: id1)
        XCTAssertEqual(model.creations.count, 1)
        XCTAssertFalse(model.creations.contains { $0.id == id1 })
        model.clearCreations()
        XCTAssertTrue(model.creations.isEmpty)
    }

    // MARK: - Version creation-status tracker

    func testVersionCreationTrackerLifecycle() {
        let tracker = CreationStatusTracker()
        let id = UUID()
        XCTAssertNil(tracker.status(id))
        tracker.begin(id)
        XCTAssertEqual(tracker.status(id), .creating)
        tracker.succeed(id)                       // clears after a linger; immediate state is .created
        XCTAssertEqual(tracker.status(id), .created)
        tracker.clear(id)
        XCTAssertNil(tracker.status(id))
    }

    func testVersionCreationTrackerFailRetryGuard() {
        let tracker = CreationStatusTracker()
        let id = UUID()
        tracker.begin(id)
        tracker.fail(id, reason: "no token")
        XCTAssertEqual(tracker.status(id), .failed("no token"))
        XCTAssertTrue(tracker.retry(id))          // failed → back to creating
        XCTAssertEqual(tracker.status(id), .creating)
        XCTAssertFalse(tracker.retry(id))         // not failed → no-op (double-tap guard)
    }

    func testVersionCreationTrackerClearAll() {
        let tracker = CreationStatusTracker()
        let a = UUID(); let b = UUID()
        tracker.begin(a); tracker.fail(b, reason: "x")
        tracker.clearAll()
        XCTAssertNil(tracker.status(a))
        XCTAssertNil(tracker.status(b))
    }

    // MARK: - makeTask helper

    private func makeTask(_ n: Int, status: TaskStatus = .todo, priority: TaskPriority = .med,
                          milestone: String? = nil, closed: Bool = false,
                          title: String? = nil, body: String = "") -> TaskItem {
        var labels = [AppFeedbackLabels.task]
        if status != .todo { labels.append(status.label) }      // .todo is the parsed default
        if priority != .med { labels.append(priority.label) }   // .med is the parsed default
        return TaskItem(issue: FeedbackIssue(
            number: n, title: title ?? "t\(n)", createdAt: Date(), rawBody: body,
            appName: nil, appVersion: nil, device: nil, osVersion: nil, email: nil, description: body,
            labels: labels.map { IssueLabel(name: $0, colorHex: "x") },
            state: closed ? .closed : .open, milestoneTitle: milestone))
    }

    // MARK: - Task filtering

    func testFilteredTasksNoFiltersReturnsAll() {
        let m = ProjectInspectorModel()
        m.setTasks([makeTask(1), makeTask(2, status: .inProgress)])
        XCTAssertEqual(m.filteredTasks.map(\.number), [1, 2])
    }

    func testFilterByMultipleStatuses() {
        let m = ProjectInspectorModel()
        m.setTasks([makeTask(1, status: .todo), makeTask(2, status: .inProgress), makeTask(3, status: .done)])
        m.taskFilters.statuses = [.todo, .inProgress]
        XCTAssertEqual(Set(m.filteredTasks.map(\.number)), [1, 2])
    }

    func testClosedTaskMatchesDoneNotTodo() {
        let m = ProjectInspectorModel()
        // A closed task reads as Done via displayStatus regardless of its raw status. (The
        // explicit status:todo-label variant is proven at the TaskItem layer in Task 1.)
        m.setTasks([makeTask(1, status: .todo, closed: true)])
        m.taskFilters.statuses = [.done]
        XCTAssertEqual(m.filteredTasks.map(\.number), [1], "closed task should match a Done filter")
        m.taskFilters.statuses = [.todo]
        XCTAssertTrue(m.filteredTasks.isEmpty, "closed task should not match a To Do filter")
    }

    func testFilterByPriority() {
        let m = ProjectInspectorModel()
        m.setTasks([makeTask(1, priority: .high), makeTask(2, priority: .low)])
        m.taskFilters.priorities = [.high]
        XCTAssertEqual(m.filteredTasks.map(\.number), [1])
    }

    func testFilterByVersion() {
        let m = ProjectInspectorModel()
        m.setTasks([makeTask(1, milestone: "1.0"), makeTask(2, milestone: "2.0"), makeTask(3, milestone: nil)])
        m.taskFilters.versionScope = .versions(["1.0"])
        XCTAssertEqual(m.filteredTasks.map(\.number), [1])
    }

    func testFilterDimensionsCombineWithAnd() {
        let m = ProjectInspectorModel()
        m.setTasks([
            makeTask(1, status: .inProgress, priority: .high, milestone: "1.0"),
            makeTask(2, status: .inProgress, priority: .low,  milestone: "1.0"),
            makeTask(3, status: .todo,       priority: .high, milestone: "1.0"),
            makeTask(4, status: .inProgress, priority: .high, milestone: "2.0"),
        ])
        m.taskFilters.statuses = [.inProgress]
        m.taskFilters.priorities = [.high]
        m.taskFilters.versionScope = .versions(["1.0"])
        // Only #1 matches all three dimensions. #4 matches status+priority but is excluded by version,
        // proving the version dimension is AND'd in (not OR'd).
        XCTAssertEqual(m.filteredTasks.map(\.number), [1])
    }

    func testFilterBySearch() {
        let m = ProjectInspectorModel()
        m.setTasks([
            makeTask(1, title: "Fix login bug"),
            makeTask(2, title: "Polish onboarding"),
        ])
        m.taskFilters.search = "login"
        XCTAssertEqual(m.filteredTasks.map(\.number), [1])
        m.taskFilters.search = "  "          // blank → no constraint
        XCTAssertEqual(m.filteredTasks.count, 2)
    }

    func testUniqueTaskVersionsDistinctSortedExcludingNil() {
        let m = ProjectInspectorModel()
        m.setTasks([makeTask(1, milestone: "2.0"), makeTask(2, milestone: "1.0"),
                    makeTask(3, milestone: "2.0"), makeTask(4, milestone: nil)])
        XCTAssertEqual(m.uniqueTaskVersions, ["1.0", "2.0"])
    }

    // MARK: - Version filtering

    func testVersionMatchesByState() {
        let m = ProjectInspectorModel()
        XCTAssertTrue(m.versionMatches(name: "1.0.0", releaseTitle: "Polish", state: .new))  // no filters → all
        m.versionFilters.states = [.released]
        XCTAssertFalse(m.versionMatches(name: "1.0.0", releaseTitle: "Polish", state: .new))
        XCTAssertTrue(m.versionMatches(name: "1.0.0", releaseTitle: "Polish", state: .released))
    }

    func testVersionMatchesBySearchOnNameOrTitle() {
        let m = ProjectInspectorModel()
        m.versionFilters.search = "pol"
        XCTAssertTrue(m.versionMatches(name: "1.0.0", releaseTitle: "Polish", state: .new))   // title
        XCTAssertFalse(m.versionMatches(name: "1.0.0", releaseTitle: "Speed", state: .new))
        m.versionFilters.search = "1.3"
        XCTAssertTrue(m.versionMatches(name: "1.3.0", releaseTitle: "x", state: .new))         // name
        XCTAssertFalse(m.versionMatches(name: "2.0.0", releaseTitle: "x", state: .new))
    }

    // MARK: - Version rename (in-memory re-point)

    func testRenameVersionRepointsLoadedTasks() {
        let model = ProjectInspectorModel()
        model.setTasks([
            makeTask(1, milestone: "1.2.0"),
            makeTask(2, milestone: "9.9"),
            makeTask(3, milestone: nil),
        ])

        model.renameVersion(from: "1.2.0", to: "1.3.0")

        XCTAssertEqual(model.tasks(forVersionNamed: "1.3.0").map(\.number), [1])
        XCTAssertTrue(model.tasks(forVersionNamed: "1.2.0").isEmpty)
        XCTAssertEqual(model.tasks(forVersionNamed: "9.9").map(\.number), [2])
        XCTAssertNil(model.task(number: 3)?.milestoneTitle, "an unassigned task must stay unassigned")
    }

    func testRenameVersionMovesTheActiveVersionFilter() {
        let model = ProjectInspectorModel()
        model.taskFilters.versionScope = .versions(["1.2.0", "1.1.0"])

        model.renameVersion(from: "1.2.0", to: "1.3.0")

        XCTAssertEqual(model.taskFilters.versionScope, .versions(["1.3.0", "1.1.0"]))
    }

    func testRenameVersionMovesTheDerivedStateEntry() {
        let model = ProjectInspectorModel()
        model.versionStates = ["1.2.0": .wip, "9.9": .new]

        model.renameVersion(from: "1.2.0", to: "1.3.0")

        XCTAssertEqual(model.versionStates["1.3.0"], .wip)
        XCTAssertNil(model.versionStates["1.2.0"])
        XCTAssertEqual(model.versionStates["9.9"], .new)
    }

    func testRenameVersionToSameNameIsNoOp() {
        let model = ProjectInspectorModel()
        model.setTasks([makeTask(1, milestone: "1.2.0")])
        model.versionStates = ["1.2.0": .wip]

        model.renameVersion(from: "1.2.0", to: "1.2.0")

        XCTAssertEqual(model.tasks(forVersionNamed: "1.2.0").map(\.number), [1])
        XCTAssertEqual(model.versionStates["1.2.0"], .wip)
    }

    // MARK: - Clearing

    func testClearFiltersResetsEverything() {
        let m = ProjectInspectorModel()
        m.taskFilters.statuses = [.done]
        m.taskFilters.search = "x"
        m.versionFilters.states = [.released]
        m.versionFilters.search = "y"
        m.clearFilters()
        XCTAssertFalse(m.taskFilters.isActive)
        XCTAssertFalse(m.versionFilters.isActive)
    }
}
