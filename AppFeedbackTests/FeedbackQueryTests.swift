import XCTest
import SwiftData
@testable import AppFeedback

#if os(macOS)
final class FeedbackQueryTests: XCTestCase {

    var context: ModelContext!
    let config = ProductConfig(displayName: "P", owner: "o", repo: "r")

    override func setUpWithError() throws {
        let modelConfig = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        context = ModelContext(try ModelContainer(
            for: CachedIssue.self, HiddenApp.self, TriageVerdictRecord.self,
                FeedbackAttachmentLocal.self,
            configurations: modelConfig))
    }

    @discardableResult
    func insert(number: Int, title: String = "T", app: String? = "Zcode",
                description: String = "d", labels: [String] = [],
                state: IssueState = .open, source: FeedbackSource = .sdk,
                rating: Int? = nil, email: String? = nil, appVersion: String? = nil,
                created: Date = Date(timeIntervalSince1970: 1_000_000),
                updated: Date? = nil, body: String = "") -> CachedIssue {
        let row = CachedIssue(repoOwner: "o", repoName: "r", number: number, title: title,
                              createdAt: created, updatedAt: updated, state: state, rawBody: body,
                              appName: app, appVersion: appVersion, device: "iPhone",
                              osVersion: "iOS 18.6", email: email, issueDescription: description,
                              labels: labels.map { IssueLabel(name: $0, colorHex: "ededed") })
        row.source = source.rawValue
        row.rating = rating
        context.insert(row)
        return row
    }

    func run(_ mutate: (inout CLIFlags) -> Void = { _ in }) -> (items: [FeedbackItem], total: Int) {
        var flags = CLIFlags()
        flags.product = "P"
        mutate(&flags)
        let index = TaskIndex.build(local: context, owner: "o", repo: "r")
        return FeedbackQuery.run(flags: flags, config: config, local: context, cloud: context, index: index)
    }

    // MARK: - Task exclusion and hidden apps

    func testExcludesTaskLabelledIssues() {
        insert(number: 1)
        insert(number: 2, labels: [AppFeedbackLabels.task])
        XCTAssertEqual(run().items.map(\.number), [1])
    }

    func testHiddenAppsAreExcludedByDefaultAndIncludableOnDemand() {
        insert(number: 1, app: "Zcode")
        insert(number: 2, app: "Secret")
        context.insert(HiddenApp(repoOwner: "o", repoName: "r", appName: "Secret"))
        XCTAssertEqual(run().items.map(\.number), [1])
        XCTAssertEqual(run { $0.includeHidden = true }.items.map(\.number).sorted(), [1, 2])
    }

    // MARK: - Filters

    func testDefaultStateIsOpenOnly() {
        insert(number: 1, state: .open)
        insert(number: 2, state: .closed)
        XCTAssertEqual(run().items.map(\.number), [1])
        XCTAssertEqual(run { $0.state = .closed }.items.map(\.number), [2])
        XCTAssertEqual(run { $0.state = .all }.items.map(\.number).sorted(), [1, 2])
    }

    func testRepeatedAppFlagOrsValues() {
        insert(number: 1, app: "Zcode")
        insert(number: 2, app: "XcodeMini")
        insert(number: 3, app: "Other")
        XCTAssertEqual(run { $0.apps = ["Zcode", "XcodeMini"] }.items.map(\.number).sorted(), [1, 2])
    }

    func testDifferentFlagsAndTogether() {
        insert(number: 1, app: "Zcode", labels: ["bug"])
        insert(number: 2, app: "Zcode", labels: ["feature-request"])
        insert(number: 3, app: "Other", labels: ["bug"])
        XCTAssertEqual(run { $0.apps = ["Zcode"]; $0.types = [.bug] }.items.map(\.number), [1])
    }

    func testLabelFilterRequiresEveryRequestedLabel() {
        insert(number: 1, labels: ["bug", "user-submitted"])
        insert(number: 2, labels: ["bug"])
        XCTAssertEqual(run { $0.labels = ["bug", "user-submitted"] }.items.map(\.number), [1])
    }

    func testSourceFilter() {
        insert(number: 1, source: .sdk)
        insert(number: 2, source: .appStore)
        XCTAssertEqual(run { $0.sources = [.appStore] }.items.map(\.number), [2])
    }

    func testRatingRangeIsInclusiveAndDropsUnrated() {
        insert(number: 1, source: .appStore, rating: 1)
        insert(number: 2, source: .appStore, rating: 3)
        insert(number: 3, source: .sdk, rating: nil)
        XCTAssertEqual(run { $0.maxRating = 2 }.items.map(\.number), [1])
        XCTAssertEqual(run { $0.minRating = 3 }.items.map(\.number), [2])
    }

    func testSinceFiltersOnCreatedAtInclusively() {
        let cutoff = Date(timeIntervalSince1970: 2_000_000)
        insert(number: 1, created: cutoff.addingTimeInterval(-1))
        insert(number: 2, created: cutoff)
        insert(number: 3, created: cutoff.addingTimeInterval(1))
        XCTAssertEqual(run { $0.since = cutoff }.items.map(\.number).sorted(), [2, 3])
    }

    func testUpdatedSinceFiltersOnUpdatedAt() {
        let cutoff = Date(timeIntervalSince1970: 2_000_000)
        insert(number: 1, created: cutoff.addingTimeInterval(-100), updated: cutoff.addingTimeInterval(-100))
        insert(number: 2, created: cutoff.addingTimeInterval(-100), updated: cutoff.addingTimeInterval(50))
        XCTAssertEqual(run { $0.updatedSince = cutoff }.items.map(\.number), [2])
    }

    func testSearchMatchesTitleDescriptionAndAppCaseInsensitively() {
        insert(number: 1, title: "Crash on launch", app: "Zcode", description: "x")
        insert(number: 2, title: "x", app: "Zcode", description: "It CRASHES sometimes")
        insert(number: 3, title: "x", app: "CrashPad", description: "y")
        insert(number: 4, title: "unrelated", app: "Zcode", description: "y")
        XCTAssertEqual(run { $0.search = "crash" }.items.map(\.number).sorted(), [1, 2, 3])
    }

    func testAppVersionFilter() {
        insert(number: 1, appVersion: "1.4.2")
        insert(number: 2, appVersion: "1.4.3")
        XCTAssertEqual(run { $0.appVersion = "1.4.2" }.items.map(\.number), [1])
    }

    func testHasTaskAndNoTask() {
        insert(number: 1)
        insert(number: 2)
        insert(number: 90, labels: [AppFeedbackLabels.task],
               body: FeedbackTaskRefParser.upsert(into: "t", refs: [1]))
        XCTAssertEqual(run { $0.hasTask = true }.items.map(\.number), [1])
        XCTAssertEqual(run { $0.hasTask = false }.items.map(\.number), [2])
    }

    // MARK: - Sorting and pagination

    func testSortsByCreatedDescendingByDefaultWithNumberTiebreak() {
        let same = Date(timeIntervalSince1970: 5_000)
        insert(number: 1, created: same)
        insert(number: 3, created: same)
        insert(number: 2, created: same.addingTimeInterval(100))
        XCTAssertEqual(run().items.map(\.number), [2, 3, 1])
    }

    func testAscendingOrder() {
        insert(number: 1, created: Date(timeIntervalSince1970: 1))
        insert(number: 2, created: Date(timeIntervalSince1970: 2))
        XCTAssertEqual(run { $0.order = .asc }.items.map(\.number), [1, 2])
    }

    func testPaginationReportsTotalAcrossPages() {
        for number in 1...5 {
            insert(number: number, created: Date(timeIntervalSince1970: TimeInterval(number)))
        }
        let page = run { $0.limit = 2; $0.offset = 1 }
        XCTAssertEqual(page.total, 5)
        XCTAssertEqual(page.items.map(\.number), [4, 3])
    }

    func testOffsetPastTheEndYieldsNoItemsButKeepsTheTotal() {
        insert(number: 1)
        let page = run { $0.offset = 99 }
        XCTAssertTrue(page.items.isEmpty)
        XCTAssertEqual(page.total, 1)
    }

    // MARK: - Item shape

    func testEmailIsRedactedByDefault() {
        insert(number: 1, email: "amir@icloud.com")
        XCTAssertEqual(run().items.first?.email, "a***@icloud.com")
        XCTAssertEqual(run { $0.includeEmails = true }.items.first?.email, "amir@icloud.com")
    }

    func testRedactionHandlesSingleCharacterAndMalformedAddresses() {
        XCTAssertEqual(FeedbackQuery.redact("a@b.com"), "a***@b.com")
        XCTAssertEqual(FeedbackQuery.redact("no-at-sign"), "***")
        XCTAssertEqual(FeedbackQuery.redact("@nolocal.com"), "***")
    }

    func testDescriptionTruncatesAtFiveHundredCharacters() {
        insert(number: 1, description: String(repeating: "x", count: 600))
        let item = run().items.first
        XCTAssertEqual(item?.description.count, 500)
        XCTAssertEqual(item?.truncated, true)
    }

    func testShortDescriptionIsNotMarkedTruncated() {
        insert(number: 1, description: "short")
        XCTAssertEqual(run().items.first?.truncated, false)
    }

    func testItemCarriesExpandedTasksAndTriage() {
        insert(number: 1)
        insert(number: 90, title: "The task", labels: [AppFeedbackLabels.task, "status:todo", "priority:high"],
               body: FeedbackTaskRefParser.upsert(into: "t", refs: [1]))
        let verdict = TriageVerdictRecord(repoOwner: "o", repoName: "r", feedbackNumber: 1,
                                          state: TriageState.accepted.rawValue)
        verdict.kind = TriageKind.usability.rawValue
        verdict.signal = "users cannot find the button"
        context.insert(verdict)

        let item = run().items.first
        XCTAssertEqual(item?.tasks.first?.number, 90)
        XCTAssertEqual(item?.tasks.first?.status, "todo")
        XCTAssertEqual(item?.tasks.first?.priority, "high")
        XCTAssertEqual(item?.triage?.state, "accepted")
        XCTAssertEqual(item?.triage?.kind, "usability")
        XCTAssertEqual(item?.triage?.signal, "users cannot find the button")
    }

    func testItemUrlPointsAtTheFeedbackRepo() {
        insert(number: 559)
        XCTAssertEqual(run().items.first?.url, "https://github.com/o/r/issues/559")
    }

    func testTypeComesFromLabels() {
        insert(number: 1, labels: ["feature-request"])
        insert(number: 2, labels: [])
        let items = run().items
        XCTAssertEqual(items.first(where: { $0.number == 1 })?.type, "feature-request")
        XCTAssertNil(items.first(where: { $0.number == 2 })?.type)
    }

    // MARK: - Detail

    func testDetailReturnsFullDescriptionAndOmitsRawBodyByDefault() throws {
        insert(number: 7, description: String(repeating: "y", count: 900), body: "RAW BODY <!-- marker -->")
        var flags = CLIFlags(); flags.product = "P"
        let index = TaskIndex.build(local: context, owner: "o", repo: "r")

        let detail = try FeedbackQuery.detail(number: 7, flags: flags, config: config,
                                              local: context, cloud: context, index: index)
        XCTAssertEqual(detail.description.count, 900)
        XCTAssertNil(detail.rawBody)

        flags.raw = true
        let withRaw = try FeedbackQuery.detail(number: 7, flags: flags, config: config,
                                               local: context, cloud: context, index: index)
        XCTAssertEqual(withRaw.rawBody, "RAW BODY <!-- marker -->")
    }

    func testDetailForUnknownNumberIsNotFound() {
        var flags = CLIFlags(); flags.product = "P"
        let index = TaskIndex.build(local: context, owner: "o", repo: "r")
        XCTAssertThrowsError(try FeedbackQuery.detail(number: 404, flags: flags, config: config,
                                                      local: context, cloud: context, index: index)) { error in
            guard let cliError = error as? CLIError, case .notFound(let code, _, _, _) = cliError else {
                return XCTFail("expected .notFound")
            }
            XCTAssertEqual(code, "feedback_not_found")
        }
    }

    func testDetailRefusesToReturnATaskAsFeedback() {
        insert(number: 8, labels: [AppFeedbackLabels.task])
        var flags = CLIFlags(); flags.product = "P"
        let index = TaskIndex.build(local: context, owner: "o", repo: "r")
        XCTAssertThrowsError(try FeedbackQuery.detail(number: 8, flags: flags, config: config,
                                                      local: context, cloud: context, index: index)) { error in
            guard let cliError = error as? CLIError, case .notFound(let code, _, let hint, _) = cliError else {
                return XCTFail("expected .notFound")
            }
            XCTAssertEqual(code, "feedback_not_found")
            XCTAssertEqual(hint, "#8 is a task. Use `tasks show 8`.")
        }
    }
}
#endif
