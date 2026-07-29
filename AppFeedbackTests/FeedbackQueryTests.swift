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
            for: CachedIssue.self, TriageVerdictRecord.self,
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

    func detail(_ number: Int, _ mutate: (inout CLIFlags) -> Void = { _ in }) throws -> FeedbackDetail {
        var flags = CLIFlags()
        flags.product = "P"
        mutate(&flags)
        let index = TaskIndex.build(local: context, owner: "o", repo: "r")
        return try FeedbackQuery.detail(number: number, flags: flags, config: config,
                                        local: context, cloud: context, index: index)
    }

    // MARK: - Task exclusion

    func testExcludesTaskLabelledIssues() {
        insert(number: 1)
        insert(number: 2, labels: [AppFeedbackLabels.task])
        XCTAssertEqual(run().items.map(\.number), [1])
    }

    // MARK: - Filters

    func testDefaultStateIsOpenOnly() {
        insert(number: 1, state: .open)
        insert(number: 2, state: .closed)
        XCTAssertEqual(run().items.map(\.number), [1])
        XCTAssertEqual(run { $0.state = .closed }.items.map(\.number), [2])
        XCTAssertEqual(run { $0.state = .all }.items.map(\.number).sorted(), [1, 2])
    }

    func testDifferentFlagsAndTogether() {
        insert(number: 1, labels: ["bug"], state: .open)
        insert(number: 2, labels: ["feature-request"], state: .open)
        insert(number: 3, labels: ["bug"], state: .closed)
        XCTAssertEqual(run { $0.labels = ["bug"]; $0.types = [.bug] }.items.map(\.number), [1])
    }

    /// `--label` is repeatable and ORs — SKILL.md promises that for every repeatable flag.
    func testRepeatedLabelFlagOrsValues() {
        insert(number: 1, labels: ["bug", "user-submitted"])
        insert(number: 2, labels: ["bug"])
        insert(number: 3, labels: ["question"])
        XCTAssertEqual(run { $0.labels = ["user-submitted", "question"] }.items.map(\.number).sorted(),
                       [1, 3])
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

    /// The detail path (`feedback show`) applies the same redaction the list path does. Two lines
    /// below it, `rawIssue` deliberately returns the UNREDACTED address for `respond`, so it is
    /// easy to wire detail to the wrong one — this test is what notices.
    func testDetailRedactsEmailUnlessIncludeEmails() throws {
        insert(number: 7, email: "amir@icloud.com")
        let redacted = try detail(7)
        let included = try detail(7, { $0.includeEmails = true })
        XCTAssertEqual(redacted.email, "a***@icloud.com")
        XCTAssertEqual(included.email, "amir@icloud.com")

        // …while the respond path still gets the real address.
        var flags = CLIFlags(); flags.product = "P"
        XCTAssertEqual(try FeedbackQuery.rawIssue(number: 7, config: config, local: context).email,
                       "amir@icloud.com")
    }

    /// The privacy contract is only kept if the address is absent from what actually reaches the
    /// user: the encoded envelope and the `--text` rendering, not just the DTO field.
    func testEncodedListOutputNeverContainsTheRealAddress() {
        insert(number: 1, email: "amir@icloud.com")

        let redacted = CLIOutput.encode(CLIEnvelope(items: run().items))
        XCTAssertFalse(redacted.contains("amir@icloud.com"),
                       "list JSON leaked the reporter address:\n\(redacted)")
        XCTAssertTrue(redacted.contains("a***@icloud.com"))

        let included = CLIOutput.encode(CLIEnvelope(items: run { $0.includeEmails = true }.items))
        XCTAssertTrue(included.contains("amir@icloud.com"), "--include-emails must pass it through")
    }

    func testEncodedDetailOutputNeverContainsTheRealAddress() throws {
        insert(number: 7, email: "amir@icloud.com")

        let redacted = CLIOutput.encode(CLIEnvelope(items: [try detail(7)]))
        XCTAssertFalse(redacted.contains("amir@icloud.com"),
                       "detail JSON leaked the reporter address:\n\(redacted)")
        XCTAssertTrue(redacted.contains("a***@icloud.com"))

        let withEmails = try detail(7, { $0.includeEmails = true })
        XCTAssertTrue(CLIOutput.encode(CLIEnvelope(items: [withEmails])).contains("amir@icloud.com"),
                      "--include-emails must pass it through")
    }

    /// `CLIText.render(detail:)` prints a `reporter:` line, so `--text` is a leak surface too.
    func testTextRenderedDetailNeverContainsTheRealAddress() throws {
        insert(number: 7, email: "amir@icloud.com")

        let redacted = CLIText.render(detail: try detail(7))
        XCTAssertTrue(redacted.contains("reporter:"), "guard is meaningless if the line vanished")
        XCTAssertFalse(redacted.contains("amir@icloud.com"),
                       "--text detail leaked the reporter address:\n\(redacted)")
        XCTAssertTrue(redacted.contains("a***@icloud.com"))

        let withEmails = try detail(7, { $0.includeEmails = true })
        XCTAssertTrue(CLIText.render(detail: withEmails).contains("amir@icloud.com"))
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
