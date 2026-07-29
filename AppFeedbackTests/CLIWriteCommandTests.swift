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
            for: Product.self, ProjectVersion.self,
                CachedIssue.self, RepoFetchState.self, TriageVerdictRecord.self,
            configurations: modelConfig))
    }

    // MARK: - Handler-level fixtures

    /// The product every handler test resolves `--product P` to. Without a row here
    /// `resolveConfig` fails before any handler logic runs.
    @discardableResult
    private func insertProduct(name: String = "P") -> Product {
        let product = Product(displayName: name, owner: "o", repo: "r")
        context.insert(product)
        return product
    }

    private func cache(_ number: Int, title: String = "Cached") {
        context.insert(CachedIssue(repoOwner: "o", repoName: "r", number: number, title: title,
                                   createdAt: Date(), rawBody: "", appName: nil, appVersion: nil,
                                   device: nil, osVersion: nil, email: nil, issueDescription: ""))
    }

    /// Real handler dependencies over in-memory contexts: nothing here reaches GitHub, the
    /// keychain or the network, so the handlers themselves are what is under test.
    private func makeDeps(writer: FakeIssueWriting,
                          token: String? = "gh-token") -> CLIRequestHandlers.Dependencies {
        CLIRequestHandlers.Dependencies(
            registry: IssueLoaderRegistry(factory: { IssueLoader(config: $0, session: .mock) },
                                          tokenProvider: { _ in nil }),
            local: context, cloud: context,
            writer: writer, tokenProvider: { _ in token })
    }

    private func linkRequest(task: String? = "90", feedback: String,
                             product: String = "P") -> CLIRequest {
        var payload = ["product": product, "feedback": feedback]
        if let task { payload["task"] = task }
        return CLIRequest(kind: .linkTask, payload: payload)
    }

    private func taskIssue(number: Int = 90, refs: [Int], prose: String = "notes",
                           labels: [String] = [AppFeedbackLabels.task, "status:in-progress",
                                               "priority:high"],
                           state: String = "open") -> FetchedIssue {
        FetchedIssue(number: number, title: "Task",
                     body: FeedbackTaskRefParser.upsert(into: prose, refs: refs),
                     labels: labels, state: state)
    }

    private func detail(_ response: CLIResponse) throws -> TaskDetail {
        try JSONDecoder().decode(TaskDetail.self,
                                 from: Data(try XCTUnwrap(response.json).utf8))
    }

    private func cliError(_ error: Error, file: StaticString = #filePath,
                          line: UInt = #line) throws -> CLIError {
        guard let cliError = error as? CLIError else {
            XCTFail("expected a CLIError, got \(error)", file: file, line: line)
            throw error
        }
        return cliError
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

    // MARK: - link / unlink through the real handler

    /// The cache says [10]; GitHub says [10, 20]. Linking 30 must PATCH [10, 20, 30] — proving
    /// the handler rewrites the LIVE body it fetched, not the stale cached one.
    func testLinkHandlerRewritesTheLiveBodyNotTheCachedOne() async throws {
        insertProduct()
        cache(10); cache(20); cache(30)
        let writer = FakeIssueWriting()
        await writer.stub(taskIssue(refs: [10, 20]))

        let response = try await CLIRequestHandlers.link(linkRequest(feedback: "30"),
                                                         deps: makeDeps(writer: writer),
                                                         removing: false)
        XCTAssertTrue(response.ok)
        let fetches = await writer.fetches
        XCTAssertEqual(fetches, [90], "the live task must be read before rewriting")

        let updates = await writer.updates
        XCTAssertEqual(updates.count, 1)
        XCTAssertEqual(FeedbackTaskRefParser.parse(try XCTUnwrap(updates[0].body)), [10, 20, 30],
                       "must union against the live body, not the cached [10]")
        XCTAssertEqual(FeedbackTaskRefParser.prose(of: try XCTUnwrap(updates[0].body)), "notes",
                       "the human prose must survive the machine-managed block rewrite")
    }

    /// A regression that also sent labels/state/milestone would silently strip a task's
    /// priority, reopen a finished task, or clear its milestone — all while exiting 0.
    func testLinkHandlerPatchesOnlyTheBody() async throws {
        insertProduct()
        cache(7)
        let writer = FakeIssueWriting()
        await writer.stub(taskIssue(refs: [], labels: [AppFeedbackLabels.task, "status:done",
                                                       "priority:high"],
                                    state: "closed"))

        _ = try await CLIRequestHandlers.link(linkRequest(feedback: "7"),
                                              deps: makeDeps(writer: writer), removing: false)

        let updates = await writer.updates
        XCTAssertEqual(updates.count, 1)
        XCTAssertEqual(updates[0].owner, "o")
        XCTAssertEqual(updates[0].repo, "r")
        XCTAssertEqual(updates[0].number, 90)
        XCTAssertNil(updates[0].title, "the title must be left untouched")
        XCTAssertNil(updates[0].labels, "labels must be left untouched")
        XCTAssertNil(updates[0].state, "state must be left untouched — a done task stays closed")
        XCTAssertNil(updates[0].milestoneNumber, "the milestone must not even be sent")
        XCTAssertEqual(FeedbackTaskRefParser.parse(try XCTUnwrap(updates[0].body)), [7])
    }

    /// The reply describes the task as it now is: refs from the newly written body, status and
    /// priority from the live labels, closed-ness from the live state.
    func testLinkHandlerReportsTheUpdatedTask() async throws {
        insertProduct()
        cache(10, title: "Crash on launch")
        cache(20, title: "Slow sync")
        let writer = FakeIssueWriting()
        await writer.stub(taskIssue(refs: [10]))

        let response = try await CLIRequestHandlers.link(linkRequest(feedback: "20"),
                                                         deps: makeDeps(writer: writer),
                                                         removing: false)
        let result = try detail(response)
        XCTAssertEqual(result.number, 90)
        XCTAssertEqual(result.title, "Task")
        XCTAssertEqual(result.status, "in-progress")
        XCTAssertEqual(result.priority, "high")
        XCTAssertFalse(result.isClosed)
        XCTAssertEqual(result.notes, "notes")
        XCTAssertEqual(result.feedback.map(\.number), [10, 20])
        XCTAssertEqual(result.feedback.map(\.title), ["Crash on launch", "Slow sync"])
        XCTAssertEqual(result.url, "https://github.com/o/r/issues/90")
    }

    func testUnlinkHandlerRemovesOnlyTheNamedRef() async throws {
        insertProduct()
        cache(10); cache(11)
        let writer = FakeIssueWriting()
        await writer.stub(taskIssue(refs: [10, 11]))

        let response = try await CLIRequestHandlers.link(linkRequest(feedback: "11"),
                                                         deps: makeDeps(writer: writer),
                                                         removing: true)
        XCTAssertTrue(response.ok)
        let updates = await writer.updates
        XCTAssertEqual(FeedbackTaskRefParser.parse(try XCTUnwrap(updates[0].body)), [10])
        XCTAssertEqual(try detail(response).feedback.map(\.number), [10])
    }

    /// The guard that stops `tasks link --task <feedback#>` from rewriting a feedback issue's
    /// body — the issue must carry the task label or nothing is written at all.
    func testLinkRejectsANumberThatIsNotATask() async throws {
        insertProduct()
        cache(10)
        let writer = FakeIssueWriting()
        await writer.stub(FetchedIssue(number: 90, title: "Crash on launch",
                                       body: "A user's report", labels: ["bug"], state: "open"))

        do {
            _ = try await CLIRequestHandlers.link(linkRequest(feedback: "10"),
                                                  deps: makeDeps(writer: writer), removing: false)
            XCTFail("expected a throw")
        } catch {
            let failure = try cliError(error)
            XCTAssertEqual(failure.code, "task_not_found")
            XCTAssertEqual(failure.exitCode, .notFound)
        }
        let updates = await writer.updates
        XCTAssertTrue(updates.isEmpty, "a non-task's body must never be rewritten")
    }

    func testLinkAgainstAnIssueGitHubDoesNotHaveIsNotFound() async throws {
        insertProduct()
        let writer = FakeIssueWriting()   // nothing stubbed ⇒ fetch 404s

        do {
            _ = try await CLIRequestHandlers.link(linkRequest(feedback: "10"),
                                                  deps: makeDeps(writer: writer), removing: false)
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual(try cliError(error).code, "task_not_found")
        }
        let updates = await writer.updates
        XCTAssertTrue(updates.isEmpty)
    }

    /// Uncached numbers may be legitimately closed-and-never-cached, so the link still happens —
    /// the user is warned, not blocked.
    func testLinkWarnsAboutAnUncachedFeedbackNumberButStillLinks() async throws {
        insertProduct()
        cache(10)
        let writer = FakeIssueWriting()
        await writer.stub(taskIssue(refs: []))

        let response = try await CLIRequestHandlers.link(linkRequest(feedback: "10,99"),
                                                         deps: makeDeps(writer: writer),
                                                         removing: false)
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.warnings.count, 1)
        XCTAssertTrue(response.warnings[0].contains("99"))
        let updates = await writer.updates
        XCTAssertEqual(FeedbackTaskRefParser.parse(try XCTUnwrap(updates[0].body)), [10, 99],
                       "the warning must not stop the link")
    }

    /// Unlinking an uncached number is the normal way to clean up a stale ref, so warning
    /// about it would be noise.
    func testUnlinkDoesNotWarnAboutUncachedNumbers() async throws {
        insertProduct()
        let writer = FakeIssueWriting()
        await writer.stub(taskIssue(refs: [99]))

        let response = try await CLIRequestHandlers.link(linkRequest(feedback: "99"),
                                                         deps: makeDeps(writer: writer),
                                                         removing: true)
        XCTAssertEqual(response.warnings, [])
        let updates = await writer.updates
        XCTAssertEqual(FeedbackTaskRefParser.parse(try XCTUnwrap(updates[0].body)), [])
    }

    func testLinkWithoutATaskNumberIsAUsageErrorAndWritesNothing() async throws {
        insertProduct()
        let writer = FakeIssueWriting()
        do {
            _ = try await CLIRequestHandlers.link(linkRequest(task: nil, feedback: "10"),
                                                  deps: makeDeps(writer: writer), removing: false)
            XCTFail("expected a throw")
        } catch {
            let failure = try cliError(error)
            XCTAssertEqual(failure.code, "missing_flag")
            XCTAssertEqual(failure.exitCode, .usage)
        }
        let fetches = await writer.fetches
        XCTAssertTrue(fetches.isEmpty)
    }

    /// Without a token there is nothing to authenticate the read with, so the handler must
    /// stop before it ever touches GitHub.
    func testLinkWithoutATokenFailsAuthBeforeReadingTheTask() async throws {
        insertProduct()
        let writer = FakeIssueWriting()
        await writer.stub(taskIssue(refs: []))

        do {
            _ = try await CLIRequestHandlers.link(linkRequest(feedback: "10"),
                                                  deps: makeDeps(writer: writer, token: nil),
                                                  removing: false)
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual(try cliError(error).exitCode, .auth)
        }
        let fetches = await writer.fetches
        XCTAssertTrue(fetches.isEmpty, "no token ⇒ no GitHub read")
    }

    func testLinkAgainstAnUnknownProductIsNotFound() async throws {
        insertProduct(name: "P")
        let writer = FakeIssueWriting()
        do {
            _ = try await CLIRequestHandlers.link(linkRequest(feedback: "10", product: "Nope"),
                                                  deps: makeDeps(writer: writer), removing: false)
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual(try cliError(error).code, "product_not_found")
        }
        let fetches = await writer.fetches
        XCTAssertTrue(fetches.isEmpty)
    }

    // MARK: - tasks create through the real handler

    /// `createTask` resolves the milestone BEFORE it creates anything, so a version with no
    /// GitHub milestone must abort rather than create a milestone-less task.
    func testCreateTaskWithAVersionThatHasNoMilestoneIsAHardError() async throws {
        insertProduct()
        context.insert(ProjectVersion(repoOwner: "o", repoName: "r", name: "1.5.0",
                                      milestoneNumber: nil))
        let request = CLIRequest(kind: .createTask,
                                 payload: ["product": "P", "title": "Fix it", "version": "1.5.0"])
        do {
            _ = try await CLIRequestHandlers.createTask(request, deps: makeDeps(writer: FakeIssueWriting()))
            XCTFail("expected a throw")
        } catch {
            let failure = try cliError(error)
            XCTAssertEqual(failure.code, "version_has_no_milestone")
            XCTAssertEqual(failure.exitCode, .notFound)
        }
    }

    func testCreateTaskWithAnUnknownVersionIsRejectedWithCandidates() async throws {
        insertProduct()
        context.insert(ProjectVersion(repoOwner: "o", repoName: "r", name: "1.4.0",
                                      milestoneNumber: 12))
        let request = CLIRequest(kind: .createTask,
                                 payload: ["product": "P", "title": "Fix it", "version": "9.9.9"])
        do {
            _ = try await CLIRequestHandlers.createTask(request, deps: makeDeps(writer: FakeIssueWriting()))
            XCTFail("expected a throw")
        } catch {
            let failure = try cliError(error)
            guard case .notFound(let code, _, _, let candidates) = failure else {
                return XCTFail("expected .notFound")
            }
            XCTAssertEqual(code, "version_not_found")
            XCTAssertEqual(candidates, ["1.4.0"])
        }
    }

    /// No `--version` means "no milestone", not "look one up": the repo here has versions, and
    /// treating a missing flag as a lookup would fail here instead of reaching the create step
    /// (which then stops on the absent token).
    func testCreateTaskWithoutAVersionSkipsMilestoneResolutionEntirely() async throws {
        insertProduct()
        context.insert(ProjectVersion(repoOwner: "o", repoName: "r", name: "1.4.0",
                                      milestoneNumber: 12))
        let request = CLIRequest(kind: .createTask, payload: ["product": "P", "title": "Fix it"])
        do {
            _ = try await CLIRequestHandlers.createTask(request, deps: makeDeps(writer: FakeIssueWriting()))
            XCTFail("expected the tokenless create to throw")
        } catch {
            let failure = try cliError(error)
            XCTAssertEqual(failure.exitCode, .auth,
                           "must fail on the missing token, i.e. past milestone resolution")
            XCTAssertNotEqual(failure.code, "version_not_found")
            XCTAssertNotEqual(failure.code, "version_has_no_milestone")
        }
    }

    func testCreateTaskAgainstAnUnknownProductIsNotFound() async throws {
        insertProduct(name: "P")
        let request = CLIRequest(kind: .createTask, payload: ["product": "Nope", "title": "Fix it"])
        do {
            _ = try await CLIRequestHandlers.createTask(request, deps: makeDeps(writer: FakeIssueWriting()))
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual(try cliError(error).code, "product_not_found")
        }
    }

    func testCreateTaskWithoutAProductIsAUsageError() async throws {
        do {
            _ = try await CLIRequestHandlers.createTask(CLIRequest(kind: .createTask, payload: [:]),
                                                        deps: makeDeps(writer: FakeIssueWriting()))
            XCTFail("expected a throw")
        } catch {
            let failure = try cliError(error)
            XCTAssertEqual(failure.code, "missing_flag")
            XCTAssertEqual(failure.exitCode, .usage)
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
