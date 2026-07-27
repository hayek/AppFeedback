import XCTest
import SwiftData
@testable import AppFeedback

#if os(macOS)
final class TaskIndexTests: XCTestCase {

    private var context: ModelContext!
    private let config = ProductConfig(displayName: "P", owner: "o", repo: "r")

    override func setUpWithError() throws {
        let modelConfig = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        context = ModelContext(try ModelContainer(for: CachedIssue.self, configurations: modelConfig))
    }

    @discardableResult
    private func insert(number: Int, title: String = "T", body: String = "",
                        labels: [String] = [], state: IssueState = .open,
                        owner: String = "o", repo: String = "r") -> CachedIssue {
        let row = CachedIssue(repoOwner: owner, repoName: repo, number: number, title: title,
                              createdAt: Date(), state: state, rawBody: body, appName: nil,
                              appVersion: nil, device: nil, osVersion: nil, email: nil,
                              issueDescription: "",
                              labels: labels.map { IssueLabel(name: $0, colorHex: "ededed") })
        context.insert(row)
        return row
    }

    private func index() -> TaskIndex {
        TaskIndex.build(local: context, owner: "o", repo: "r")
    }

    // MARK: - Indexing

    func testIndexesOnlyTaskLabelledIssues() {
        insert(number: 1, labels: ["bug"])
        insert(number: 2, labels: [AppFeedbackLabels.task])
        XCTAssertEqual(index().tasks.map(\.number), [2])
    }

    func testReverseMapLinksFeedbackToItsTasks() {
        insert(number: 2, title: "Fix the thing",
               body: FeedbackTaskRefParser.upsert(into: "Fix it", refs: [10, 11]),
               labels: [AppFeedbackLabels.task, "status:in-progress", "priority:high"])

        let map = index()
        let refs = map.refs(forFeedback: 10)
        XCTAssertEqual(refs.count, 1)
        XCTAssertEqual(refs.first?.number, 2)
        XCTAssertEqual(refs.first?.title, "Fix the thing")
        XCTAssertEqual(refs.first?.status, "in-progress")
        XCTAssertEqual(refs.first?.priority, "high")
        XCTAssertEqual(map.refs(forFeedback: 11).first?.number, 2)
        XCTAssertTrue(map.refs(forFeedback: 99).isEmpty)
    }

    func testOneFeedbackCanHaveSeveralTasks() {
        insert(number: 2, body: FeedbackTaskRefParser.upsert(into: "A", refs: [10]),
               labels: [AppFeedbackLabels.task])
        insert(number: 3, body: FeedbackTaskRefParser.upsert(into: "B", refs: [10]),
               labels: [AppFeedbackLabels.task])
        XCTAssertEqual(index().refs(forFeedback: 10).map(\.number).sorted(), [2, 3])
    }

    /// Closed/done tasks still count as "this is tracked" — that is the point of the field.
    func testClosedTasksAreIncludedAndReportDoneStatus() throws {
        insert(number: 2, body: FeedbackTaskRefParser.upsert(into: "A", refs: [10]),
               labels: [AppFeedbackLabels.task, "status:todo"], state: .closed)
        let ref = try XCTUnwrap(index().refs(forFeedback: 10).first)
        XCTAssertTrue(ref.isClosed)
        XCTAssertEqual(ref.status, "done", "a closed task displays as done")
    }

    func testScopedToTheRequestedRepo() {
        insert(number: 2, body: FeedbackTaskRefParser.upsert(into: "A", refs: [10]),
               labels: [AppFeedbackLabels.task])
        insert(number: 3, body: FeedbackTaskRefParser.upsert(into: "B", refs: [10]),
               labels: [AppFeedbackLabels.task], owner: "other", repo: "repo")
        XCTAssertEqual(index().refs(forFeedback: 10).map(\.number), [2])
    }

    // MARK: - Filtering

    func testFilterByStatusOrsValues() {
        insert(number: 1, labels: [AppFeedbackLabels.task, "status:todo"])
        insert(number: 2, labels: [AppFeedbackLabels.task, "status:in-progress"])
        insert(number: 3, labels: [AppFeedbackLabels.task, "status:done"])
        var flags = CLIFlags(); flags.statuses = [.todo, .inProgress]
        XCTAssertEqual(index().filter(flags).map(\.number).sorted(), [1, 2])
    }

    func testFilterByPriorityAndSearch() {
        insert(number: 1, title: "Fix crash", labels: [AppFeedbackLabels.task, "priority:high"])
        insert(number: 2, title: "Polish UI", labels: [AppFeedbackLabels.task, "priority:high"])
        insert(number: 3, title: "Fix crash", labels: [AppFeedbackLabels.task, "priority:low"])
        var flags = CLIFlags(); flags.priorities = [.high]; flags.search = "crash"
        XCTAssertEqual(index().filter(flags).map(\.number), [1])
    }

    func testFilterByVersionMatchesMilestoneTitle() {
        let row = insert(number: 1, labels: [AppFeedbackLabels.task])
        row.milestoneTitle = "1.4.0"
        insert(number: 2, labels: [AppFeedbackLabels.task])
        var flags = CLIFlags(); flags.version = "1.4.0"
        XCTAssertEqual(index().filter(flags).map(\.number), [1])
    }

    func testDefaultStateFilterExcludesDone() {
        insert(number: 1, labels: [AppFeedbackLabels.task, "status:todo"])
        insert(number: 2, labels: [AppFeedbackLabels.task, "status:done"])
        var flags = CLIFlags()          // state defaults to .open
        XCTAssertEqual(index().filter(flags).map(\.number), [1])
        flags.state = .all
        XCTAssertEqual(index().filter(flags).map(\.number).sorted(), [1, 2])
    }

    /// `tasks --status done` is documented, so it must return the done tasks rather than being
    /// silently cancelled out by the `--state open` default.
    func testExplicitDoneStatusSurvivesTheOpenStateDefault() {
        insert(number: 1, labels: [AppFeedbackLabels.task, "status:todo"])
        insert(number: 2, labels: [AppFeedbackLabels.task, "status:done"])
        insert(number: 3, labels: [AppFeedbackLabels.task, "status:todo"], state: .closed)
        var flags = CLIFlags()          // state defaults to .open
        flags.statuses = [.done]
        XCTAssertEqual(index().filter(flags).map(\.number).sorted(), [2, 3],
                       "a closed task displays as done and belongs in this result too")
    }

    // MARK: - DTO and detail

    func testDTOCarriesRefsAndURL() {
        insert(number: 90, title: "T", body: FeedbackTaskRefParser.upsert(into: "n", refs: [1, 2]),
               labels: [AppFeedbackLabels.task])
        let dto = TaskIndex.dto(index().tasks[0], config: config)
        XCTAssertEqual(dto.feedback, [1, 2])
        XCTAssertEqual(dto.url, "https://github.com/o/r/issues/90")
    }

    func testDetailExpandsLinkedFeedbackTitles() throws {
        insert(number: 10, title: "Users report a crash")
        insert(number: 90, title: "Fix the crash",
               body: FeedbackTaskRefParser.upsert(into: "Root-cause it", refs: [10]),
               labels: [AppFeedbackLabels.task])
        let detail = try index().detail(number: 90, config: config, local: context)
        XCTAssertEqual(detail.notes, "Root-cause it")
        XCTAssertEqual(detail.feedback.first?.number, 10)
        XCTAssertEqual(detail.feedback.first?.title, "Users report a crash")
    }

    func testDetailForUnknownTaskIsNotFound() {
        XCTAssertThrowsError(try index().detail(number: 404, config: config, local: context)) { error in
            guard let cliError = error as? CLIError, case .notFound(let code, _, _, _) = cliError else {
                return XCTFail("expected .notFound")
            }
            XCTAssertEqual(code, "task_not_found")
        }
    }
}
#endif
