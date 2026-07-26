import XCTest
import SwiftData
@testable import AppFeedback

#if os(macOS)
@MainActor
final class CLIWriteCommandTests: XCTestCase {

    private var context: ModelContext!
    private let config = ProductConfig(displayName: "P", owner: "o", repo: "r")

    override func setUpWithError() throws {
        let modelConfig = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        context = ModelContext(try ModelContainer(
            for: CachedIssue.self, ProjectVersion.self, configurations: modelConfig))
    }

    // MARK: - Milestone resolution

    func testResolvesVersionNameToMilestoneNumber() throws {
        context.insert(ProjectVersion(repoOwner: "o", repoName: "r", name: "1.4.0", milestoneNumber: 12))
        XCTAssertEqual(try CLIRequestHandlers.milestoneNumber(forVersion: "1.4.0",
                                                              config: config, cloud: context), 12)
    }

    /// Collapsing this to `.some(nil)` would silently CLEAR the task's milestone.
    func testNilMilestoneNumberIsAHardErrorNotASilentClear() {
        context.insert(ProjectVersion(repoOwner: "o", repoName: "r", name: "1.5.0", milestoneNumber: nil))
        XCTAssertThrowsError(try CLIRequestHandlers.milestoneNumber(forVersion: "1.5.0",
                                                                    config: config, cloud: context)) { error in
            guard let cliError = error as? CLIError, case .notFound(let code, _, _, _) = cliError else {
                return XCTFail("expected .notFound")
            }
            XCTAssertEqual(code, "version_has_no_milestone")
        }
    }

    func testUnknownVersionIsNotFoundWithCandidates() {
        context.insert(ProjectVersion(repoOwner: "o", repoName: "r", name: "1.4.0", milestoneNumber: 12))
        XCTAssertThrowsError(try CLIRequestHandlers.milestoneNumber(forVersion: "9.9.9",
                                                                    config: config, cloud: context)) { error in
            guard let cliError = error as? CLIError,
                  case .notFound(let code, _, _, let candidates) = cliError else {
                return XCTFail("expected .notFound")
            }
            XCTAssertEqual(code, "version_not_found")
            XCTAssertEqual(candidates, ["1.4.0"])
        }
    }

    func testNoVersionRequestedMeansNoMilestone() throws {
        XCTAssertNil(try CLIRequestHandlers.milestoneNumber(forVersion: nil, config: config, cloud: context))
        XCTAssertNil(try CLIRequestHandlers.milestoneNumber(forVersion: "", config: config, cloud: context))
    }

    // MARK: - Body and labels

    func testCreateBuildsTheAddressesBlockFromFeedbackRefs() {
        let body = TaskService.body(prose: "Root-cause it", feedbackRefs: [12, 34])
        XCTAssertEqual(FeedbackTaskRefParser.parse(body), [12, 34])
        XCTAssertTrue(body.hasPrefix("Root-cause it"))
    }

    func testCreateUsesTaskStatusAndPriorityLabels() {
        let labels = TaskService.labels(status: .inProgress, priority: .high)
        XCTAssertEqual(Set(labels), Set([AppFeedbackLabels.task, "status:in-progress", "priority:high"]))
    }

    // MARK: - Ref-set maths

    func testLinkUnionsWithTheLiveRefsAndSorts() {
        let live = FeedbackTaskRefParser.upsert(into: "notes", refs: [10, 12])
        let updated = CLIRequestHandlers.rewriteRefs(in: live, adding: [11, 10], removing: [])
        XCTAssertEqual(FeedbackTaskRefParser.parse(updated), [10, 11, 12])
        XCTAssertEqual(FeedbackTaskRefParser.prose(of: updated), "notes")
    }

    func testUnlinkSubtracts() {
        let live = FeedbackTaskRefParser.upsert(into: "notes", refs: [10, 11, 12])
        let updated = CLIRequestHandlers.rewriteRefs(in: live, adding: [], removing: [11])
        XCTAssertEqual(FeedbackTaskRefParser.parse(updated), [10, 12])
    }

    func testUnlinkingEverythingRemovesTheBlockButKeepsTheProse() {
        let live = FeedbackTaskRefParser.upsert(into: "notes", refs: [10])
        let updated = CLIRequestHandlers.rewriteRefs(in: live, adding: [], removing: [10])
        XCTAssertEqual(FeedbackTaskRefParser.parse(updated), [])
        XCTAssertEqual(updated.trimmingCharacters(in: .whitespacesAndNewlines), "notes")
    }

    func testUnknownFeedbackNumbersProduceWarningsNotFailures() {
        context.insert(CachedIssue(repoOwner: "o", repoName: "r", number: 10, title: "T",
                                   createdAt: Date(), rawBody: "", appName: nil, appVersion: nil,
                                   device: nil, osVersion: nil, email: nil, issueDescription: ""))
        let warnings = CLIRequestHandlers.warnAboutUncached([10, 99], config: config, local: context)
        XCTAssertEqual(warnings.count, 1)
        XCTAssertTrue(warnings[0].contains("99"))
    }

    func testNumberParsingIgnoresWhitespaceAndJunk() {
        XCTAssertEqual(CLIRequestHandlers.numbers("12, 34"), [12, 34])
        XCTAssertEqual(CLIRequestHandlers.numbers(nil), [])
        XCTAssertEqual(CLIRequestHandlers.numbers(""), [])
    }

    // MARK: - link against a fake writer

    /// The cache says [10]; GitHub says [10, 20]. Linking 30 must yield [10, 20, 30] — proving
    /// the rewrite happens against the LIVE body, not the stale cached one.
    func testLinkRewritesTheLiveBodyNotTheCachedOne() async throws {
        let writer = FakeIssueWriting()
        await writer.stub(FetchedIssue(number: 90, title: "Task",
                                       body: FeedbackTaskRefParser.upsert(into: "notes", refs: [10, 20]),
                                       labels: [AppFeedbackLabels.task, "status:todo"], state: "open"))

        let live = try await writer.fetchIssue(owner: "o", repo: "r", number: 90, token: "t")
        let updated = CLIRequestHandlers.rewriteRefs(in: live.body, adding: [30], removing: [])
        XCTAssertEqual(FeedbackTaskRefParser.parse(updated), [10, 20, 30],
                       "must union against the live body, not the cached [10]")
    }

    func testLinkPatchesOnlyTheBody() async throws {
        let writer = FakeIssueWriting()
        try await writer.updateIssue(owner: "o", repo: "r", number: 90, title: nil,
                                     body: CLIRequestHandlers.rewriteRefs(in: "notes",
                                                                          adding: [7], removing: []),
                                     labels: nil, milestoneNumber: nil, state: nil, token: "t")
        let updates = await writer.updates
        XCTAssertEqual(updates.count, 1)
        XCTAssertEqual(updates[0].number, 90)
        XCTAssertNil(updates[0].labels, "labels must be left untouched")
        XCTAssertNil(updates[0].state, "state must be left untouched")
        XCTAssertEqual(FeedbackTaskRefParser.parse(try XCTUnwrap(updates[0].body)), [7])
    }

    func testFetchingAnUnstubbedIssueThrowsNotFound() async {
        let writer = FakeIssueWriting()
        do {
            _ = try await writer.fetchIssue(owner: "o", repo: "r", number: 404, token: "t")
            XCTFail("expected a throw")
        } catch let error as GitHubIssueWriter.WriteError {
            XCTAssertTrue(error.isNotFound)
        } catch {
            XCTFail("expected WriteError, got \(error)")
        }
    }

    // MARK: - respond channel selection

    private func issue(number: Int = 1, source: FeedbackSource, email: String?) -> FeedbackIssue {
        FeedbackIssue(number: number, title: "T", createdAt: Date(), rawBody: "", appName: nil,
                      appVersion: nil, device: nil, osVersion: nil, email: email,
                      description: "", labels: [], source: source)
    }

    func testAppStoreFeedbackAutoSelectsTheAppStoreChannel() throws {
        XCTAssertEqual(try CLIRequestHandlers.channel(for: issue(source: .appStore, email: nil),
                                                      requested: .auto), .appStore)
    }

    func testEmailSourceAutoSelectsEmail() throws {
        XCTAssertEqual(try CLIRequestHandlers.channel(for: issue(source: .email, email: "a@b.com"),
                                                      requested: .auto), .email)
    }

    func testSDKWithAnAddressAutoSelectsEmail() throws {
        XCTAssertEqual(try CLIRequestHandlers.channel(for: issue(source: .sdk, email: "a@b.com"),
                                                      requested: .auto), .email)
    }

    func testSDKWithoutAnAddressHasNoAutoChannel() {
        XCTAssertThrowsError(try CLIRequestHandlers.channel(for: issue(source: .sdk, email: nil),
                                                            requested: .auto)) { error in
            guard let cliError = error as? CLIError, case .notFound(let code, _, let hint, _) = cliError else {
                return XCTFail("expected .notFound")
            }
            XCTAssertEqual(code, "no_reply_channel")
            XCTAssertTrue(hint?.contains("--via comment") == true)
        }
    }

    func testAnExplicitChannelOverridesAutoSelection() throws {
        XCTAssertEqual(try CLIRequestHandlers.channel(for: issue(source: .appStore, email: nil),
                                                      requested: .comment), .comment)
        XCTAssertEqual(try CLIRequestHandlers.channel(for: issue(source: .sdk, email: "a@b.com"),
                                                      requested: .appStore), .appStore)
    }

    func testExplicitEmailWithoutAnAddressIsAnError() {
        XCTAssertThrowsError(try CLIRequestHandlers.channel(for: issue(source: .sdk, email: ""),
                                                            requested: .email))
    }

    func testAppStoreBodyLengthIsValidatedAgainstTheDocumentedCap() {
        let tooLong = String(repeating: "x", count: AppStoreResponseController.maxBodyLength + 1)
        XCTAssertThrowsError(try CLIRequestHandlers.validateAppStoreBody(tooLong)) { error in
            guard let cliError = error as? CLIError, case .usage(let usage) = cliError else {
                return XCTFail("expected .usage")
            }
            XCTAssertEqual(usage.code, "bad_value")
        }
        XCTAssertNoThrow(try CLIRequestHandlers.validateAppStoreBody("short"))
        XCTAssertNoThrow(try CLIRequestHandlers.validateAppStoreBody(
            String(repeating: "x", count: AppStoreResponseController.maxBodyLength)))
    }

    // MARK: - Remote failure mapping

    /// The app sends the exit code it actually hit, so an error code it has never seen before
    /// still round-trips to the right exit status.
    func testRemoteFailureUsesTheExitCodeTheAppReported() {
        func mapped(_ code: CLIExitCode) -> CLIExitCode {
            CLIRunner.mapRemote(CLIResponse(id: UUID(), ok: false, errorCode: "anything",
                                            errorMessage: "m",
                                            errorExitCode: code.rawValue)).exitCode
        }
        XCTAssertEqual(mapped(.usage), .usage)
        XCTAssertEqual(mapped(.notFound), .notFound)
        XCTAssertEqual(mapped(.noLocalData), .noLocalData)
        XCTAssertEqual(mapped(.auth), .auth)
        XCTAssertEqual(mapped(.remote), .remote)
        XCTAssertEqual(mapped(.appNotRunning), .appNotRunning)
    }

    /// Every CLIError the app can raise must survive the round trip with its exit code intact.
    func testEveryAppSideErrorRoundTripsItsExitCode() {
        let errors: [CLIError] = [
            .usage(CLIUsageError(code: "missing_flag", message: "m")),
            .notFound(code: "no_reply_channel", message: "m"),
            .noLocalData(message: "m", hint: nil),
            .auth(message: "m", hint: nil),
            .remote(message: "m"),
        ]
        for error in errors {
            let response = CLIResponse(id: UUID(), ok: false, errorCode: error.code,
                                       errorMessage: error.message, errorHint: error.hint,
                                       errorExitCode: error.exitCode.rawValue)
            XCTAssertEqual(CLIRunner.mapRemote(response).exitCode, error.exitCode,
                           "\(error.code) should map back to \(error.exitCode)")
            XCTAssertEqual(CLIRunner.mapRemote(response).code, error.code)
        }
    }

    /// A response from an older app build carries no exit code — degrade to remote, not crash.
    func testMissingExitCodeFallsBackToRemote() {
        XCTAssertEqual(CLIRunner.mapRemote(CLIResponse(id: UUID(), ok: false, errorCode: "x",
                                                       errorMessage: "m")).exitCode, .remote)
    }

    func testRemoteFailurePreservesHint() {
        let error = CLIRunner.mapRemote(CLIResponse(id: UUID(), ok: false, errorCode: "auth",
                                                    errorMessage: "m", errorHint: "Re-authenticate",
                                                    errorExitCode: CLIExitCode.auth.rawValue))
        XCTAssertEqual(error.hint, "Re-authenticate")
    }
}
#endif
