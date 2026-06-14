import XCTest
@testable import AppFeedback

@MainActor
final class TaskVersionFilterTests: XCTestCase {

    private func task(_ number: Int, milestone: String? = nil) -> TaskItem {
        TaskItem(issue: FeedbackIssue(number: number, title: "t\(number)", createdAt: Date(), rawBody: "",
            appName: nil, appVersion: nil, device: nil, osVersion: nil, email: nil, description: "",
            labels: [IssueLabel(name: AppFeedbackLabels.task, colorHex: "x")], state: .open, milestoneTitle: milestone))
    }

    // MARK: override semantics

    func test_toggleState_selectsThenClears() {
        var f = TaskFilters()
        f.toggleState(.released)
        XCTAssertEqual(f.versionScope, .state(.released))
        f.toggleState(.released)                       // re-tap clears
        XCTAssertEqual(f.versionScope, .any)
    }

    func test_toggleState_overridesAnotherState() {
        var f = TaskFilters()
        f.toggleState(.new)
        f.toggleState(.released)                       // single-select: replaces
        XCTAssertEqual(f.versionScope, .state(.released))
    }

    func test_toggleUnassigned_selectsThenClears() {
        var f = TaskFilters()
        f.toggleUnassigned()
        XCTAssertEqual(f.versionScope, .unassigned)
        f.toggleUnassigned()                           // re-tap clears
        XCTAssertEqual(f.versionScope, .any)
    }

    func test_toggleUnassigned_overridesState_andStateOverridesUnassigned() {
        var f = TaskFilters()
        f.toggleState(.new)
        f.toggleUnassigned()                           // single-select: replaces the state
        XCTAssertEqual(f.versionScope, .unassigned)
        f.toggleState(.released)                        // a state replaces unassigned
        XCTAssertEqual(f.versionScope, .state(.released))
    }

    func test_isUnassignedSelected() {
        var f = TaskFilters()
        XCTAssertFalse(f.isUnassignedSelected)
        f.toggleUnassigned()
        XCTAssertTrue(f.isUnassignedSelected)
        XCTAssertFalse(f.isStateSelected(.new))
    }

    func test_toggleVersion_overridesState_thenIsAdditive() {
        var f = TaskFilters()
        f.toggleState(.new)
        f.toggleVersion("2.8")                          // version overrides state
        XCTAssertEqual(f.versionScope, .versions(["2.8"]))
        f.toggleVersion("2.6")                          // second version is additive
        XCTAssertEqual(f.versionScope, .versions(["2.8", "2.6"]))
        f.toggleVersion("2.8")                          // toggling off
        XCTAssertEqual(f.versionScope, .versions(["2.6"]))
        f.toggleVersion("2.6")                          // emptied → .any
        XCTAssertEqual(f.versionScope, .any)
    }

    func test_isStateSelected_and_isVersionSelected() {
        var f = TaskFilters()
        f.toggleState(.wip)
        XCTAssertTrue(f.isStateSelected(.wip))
        XCTAssertFalse(f.isStateSelected(.new))
        f.toggleVersion("1.0")
        XCTAssertTrue(f.isVersionSelected("1.0"))
        XCTAssertFalse(f.isStateSelected(.wip))
    }

    // MARK: filteredTasks

    func test_filter_byState_resolvesViaVersionStates() {
        let model = ProjectInspectorModel()
        model.setTasks([task(1, milestone: "1.0"), task(2, milestone: "2.0"), task(3, milestone: nil)])
        model.versionStates = ["1.0": .released, "2.0": .new]
        model.taskFilters.versionScope = .state(.new)
        XCTAssertEqual(model.filteredTasks.map(\.number), [2])   // version-less + released excluded
    }

    func test_filter_byUnassigned_returnsOnlyVersionlessTasks() {
        let model = ProjectInspectorModel()
        model.setTasks([task(1, milestone: "1.0"), task(2, milestone: nil), task(3, milestone: "2.0")])
        model.taskFilters.versionScope = .unassigned
        XCTAssertEqual(model.filteredTasks.map(\.number), [2])   // only the version-less task
    }

    func test_filter_byVersions_matchesNames() {
        let model = ProjectInspectorModel()
        model.setTasks([task(1, milestone: "1.0"), task(2, milestone: "2.0")])
        model.taskFilters.versionScope = .versions(["2.0"])
        XCTAssertEqual(model.filteredTasks.map(\.number), [2])
    }

    func test_filter_any_returnsAll() {
        let model = ProjectInspectorModel()
        model.setTasks([task(1, milestone: "1.0"), task(2, milestone: nil)])
        XCTAssertEqual(model.filteredTasks.count, 2)
    }

    func test_isActive_reflectsVersionScope() {
        var f = TaskFilters()
        XCTAssertFalse(f.isActive)
        f.toggleState(.released)
        XCTAssertTrue(f.isActive)
    }
}
