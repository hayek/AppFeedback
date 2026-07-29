import XCTest
@testable import AppFeedback

#if os(macOS)
final class CLIInvocationTests: XCTestCase {

    private func parse(_ args: String...) -> Result<CLICommand, CLIUsageError>? {
        CLIInvocation.parse(["/path/to/AppFeedback"] + args)
    }

    // MARK: - Allowlist

    func testNoArgumentsIsNotCLI() {
        XCTAssertNil(CLIInvocation.parse(["/path/to/AppFeedback"]))
    }

    func testFinderProcessSerialNumberIsNotCLI() {
        XCTAssertNil(parse("-psn_0_123456"))
    }

    func testXcodeLaunchArgumentsAreNotCLI() {
        XCTAssertNil(parse("-NSDocumentRevisionsDebugMode", "YES"))
    }

    func testUnknownNounIsNotCLI() {
        XCTAssertNil(parse("frobnicate"))
    }

    func testKnownNounIsCLI() {
        XCTAssertNotNil(parse("products"))
    }

    func testHelpAndVersion() {
        guard case .success(.help(nil))? = parse("help") else { return XCTFail("help") }
        guard case .success(.help("feedback"))? = parse("help", "feedback") else { return XCTFail("help sub") }
        guard case .success(.version)? = parse("--version") else { return XCTFail("version") }
    }

    // MARK: - Bare noun defaults to list

    func testBareFeedbackNounMeansList() {
        guard case .success(.feedback(.list(let flags)))? = parse("feedback", "--product", "P")
        else { return XCTFail("expected list") }
        XCTAssertEqual(flags.product, "P")
    }

    func testExplicitListVerb() {
        guard case .success(.feedback(.list))? = parse("feedback", "list", "--product", "P")
        else { return XCTFail("expected list") }
    }

    func testFeedbackShowParsesNumber() {
        guard case .success(.feedback(.show(let number, let flags)))? =
                parse("feedback", "show", "559", "--product", "P")
        else { return XCTFail("expected show") }
        XCTAssertEqual(number, 559)
        XCTAssertEqual(flags.product, "P")
    }

    // MARK: - Defaults

    func testListDefaults() {
        guard case .success(.feedback(.list(let f)))? = parse("feedback", "--product", "P")
        else { return XCTFail() }
        XCTAssertEqual(f.limit, 20)
        XCTAssertEqual(f.offset, 0)
        XCTAssertEqual(f.state, .open)
        XCTAssertEqual(f.sort, .created)
        XCTAssertEqual(f.order, .desc)
        XCTAssertTrue(f.json, "JSON is the default output")
        XCTAssertFalse(f.includeEmails)
        XCTAssertFalse(f.refresh)
    }

    func testTextFlagTurnsOffJSON() {
        guard case .success(.feedback(.list(let f)))? = parse("feedback", "--product", "P", "--text")
        else { return XCTFail() }
        XCTAssertFalse(f.json)
    }

    // MARK: - Repeatable flags OR their values

    func testRepeatedLabelFlagAccumulates() {
        guard case .success(.feedback(.list(let f)))? =
                parse("feedback", "--product", "P", "--label", "bug", "--label", "question")
        else { return XCTFail() }
        XCTAssertEqual(f.labels, ["bug", "question"])
    }

    func testRepeatedStatusOnTasksAccumulates() {
        guard case .success(.tasks(.list(let f)))? =
                parse("tasks", "--product", "P", "--status", "todo", "--status", "in-progress")
        else { return XCTFail() }
        XCTAssertEqual(f.statuses, [.todo, .inProgress])
    }

    func testFeedbackNumbersParseCommaSeparatedAndHashPrefixed() {
        guard case .success(.tasks(.link(let f)))? =
                parse("tasks", "link", "--product", "P", "--task", "5", "--feedback", "12,#34")
        else { return XCTFail() }
        XCTAssertEqual(f.feedbackNumbers, [12, 34])
    }

    // MARK: - Validation

    func testMissingRequiredProductIsUsageError() {
        guard case .failure(let error)? = parse("feedback") else { return XCTFail() }
        XCTAssertEqual(error.code, "missing_flag")
        XCTAssertTrue(error.message.contains("--product"))
    }

    func testUnknownFlagIsUsageError() {
        guard case .failure(let error)? = parse("feedback", "--product", "P", "--nope") else { return XCTFail() }
        XCTAssertEqual(error.code, "unknown_flag")
    }

    func testBadEnumValueIsUsageErrorListingValidValues() {
        guard case .failure(let error)? = parse("feedback", "--product", "P", "--state", "sideways")
        else { return XCTFail() }
        XCTAssertEqual(error.code, "bad_value")
        XCTAssertTrue(error.message.contains("open"), error.message)
    }

    func testLimitAboveMaximumIsUsageError() {
        guard case .failure(let error)? = parse("feedback", "--product", "P", "--limit", "500")
        else { return XCTFail() }
        XCTAssertEqual(error.code, "bad_value")
    }

    func testHasTaskAndNoTaskTogetherIsUsageError() {
        guard case .failure(let error)? = parse("feedback", "--product", "P", "--has-task", "--no-task")
        else { return XCTFail() }
        XCTAssertEqual(error.code, "conflicting_flags")
    }

    func testFlagMissingItsValueIsUsageError() {
        guard case .failure(let error)? = parse("feedback", "--product") else { return XCTFail() }
        XCTAssertEqual(error.code, "missing_value")
    }

    func testTasksCreateRequiresTitle() {
        guard case .failure(let error)? = parse("tasks", "create", "--product", "P") else { return XCTFail() }
        XCTAssertEqual(error.code, "missing_flag")
        XCTAssertTrue(error.message.contains("--title"))
    }

    func testTasksLinkRequiresTaskAndFeedback() {
        guard case .failure(let missingTask)? = parse("tasks", "link", "--product", "P", "--feedback", "1")
        else { return XCTFail() }
        XCTAssertTrue(missingTask.message.contains("--task"))

        guard case .failure(let missingFeedback)? = parse("tasks", "link", "--product", "P", "--task", "1")
        else { return XCTFail() }
        XCTAssertTrue(missingFeedback.message.contains("--feedback"))
    }

    func testRespondRequiresExactlyOneFeedbackAndABody() {
        guard case .failure(let noBody)? = parse("respond", "--product", "P", "--feedback", "1")
        else { return XCTFail() }
        XCTAssertTrue(noBody.message.contains("--body"))

        guard case .failure(let twoItems)? =
                parse("respond", "--product", "P", "--feedback", "1,2", "--body", "hi")
        else { return XCTFail() }
        XCTAssertTrue(twoItems.message.contains("exactly one"))
    }

    func testMinRatingAboveMaxRatingIsUsageError() {
        guard case .failure(let error)? =
                parse("feedback", "--product", "P", "--min-rating", "4", "--max-rating", "2")
        else { return XCTFail() }
        XCTAssertEqual(error.code, "bad_value")
    }

    // MARK: - Date parsing

    func testRelativeSinceIsResolvedAgainstNow() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(CLIInvocation.parseDate("7d", now: now), now.addingTimeInterval(-7 * 86_400))
        XCTAssertEqual(CLIInvocation.parseDate("24h", now: now), now.addingTimeInterval(-24 * 3_600))
    }

    func testAbsoluteSinceIsUTCMidnight() throws {
        let parsed = try XCTUnwrap(CLIInvocation.parseDate("2026-07-01", now: Date()))
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let components = utc.dateComponents([.year, .month, .day, .hour], from: parsed)
        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 7)
        XCTAssertEqual(components.day, 1)
        XCTAssertEqual(components.hour, 0)
    }

    func testGarbageDateIsNil() {
        XCTAssertNil(CLIInvocation.parseDate("last tuesday", now: Date()))
    }

    // MARK: - Branding is the single source of truth

    func testBrandingDrivesIPCNames() {
        XCTAssertTrue(CLIBranding.requestNotification.hasPrefix(CLIBranding.ipcPrefix))
        XCTAssertTrue(CLIBranding.responseNotification.hasPrefix(CLIBranding.ipcPrefix))
        XCTAssertNotEqual(CLIBranding.requestNotification, CLIBranding.responseNotification)
    }
}

final class CLIExitCodeTests: XCTestCase {

    func testExitCodesMatchTheContract() {
        XCTAssertEqual(CLIExitCode.success.rawValue, 0)
        XCTAssertEqual(CLIExitCode.usage.rawValue, 1)
        XCTAssertEqual(CLIExitCode.notFound.rawValue, 2)
        XCTAssertEqual(CLIExitCode.noLocalData.rawValue, 3)
        XCTAssertEqual(CLIExitCode.auth.rawValue, 4)
        XCTAssertEqual(CLIExitCode.remote.rawValue, 5)
        XCTAssertEqual(CLIExitCode.appNotRunning.rawValue, 6)
        XCTAssertEqual(CLIExitCode.watchdog.rawValue, 7)
    }

    func testUsageErrorMapsToUsageExit() {
        let error = CLIError.usage(CLIUsageError(code: "unknown_flag", message: "nope"))
        XCTAssertEqual(error.exitCode, .usage)
        XCTAssertEqual(error.code, "unknown_flag")
    }

    func testNotFoundCarriesCandidates() {
        let error = CLIError.notFound(code: "product_ambiguous", message: "m", hint: "h",
                                      candidates: ["a", "b"])
        XCTAssertEqual(error.exitCode, .notFound)
        XCTAssertEqual(error.candidates, ["a", "b"])
        XCTAssertEqual(error.hint, "h")
    }

    func testAppNotRunningHasItsOwnCodeAndHint() {
        let error = CLIError.appNotRunning
        XCTAssertEqual(error.exitCode, .appNotRunning)
        XCTAssertEqual(error.code, "app_not_running")
        XCTAssertNotNil(error.hint)
    }
}
#endif
