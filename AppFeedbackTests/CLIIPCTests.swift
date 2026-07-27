import XCTest
@testable import AppFeedback

#if os(macOS)
final class CLIIPCTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL.temporaryDirectory.appending(path: "cliipc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testRequestRoundTrips() throws {
        let request = CLIRequest(kind: .createTask,
                                 payload: ["title": "Fix the crash", "product": "P"])
        try CLIIPCTransport.write(request: request, in: directory)
        let recovered = try CLIIPCTransport.readRequest(id: request.id, in: directory)
        XCTAssertEqual(recovered.kind, .createTask)
        XCTAssertEqual(recovered.payload["title"], "Fix the crash")
    }

    func testResponseRoundTrips() throws {
        let id = UUID()
        try CLIIPCTransport.write(
            response: CLIResponse(id: id, ok: true, warnings: ["#99 is not cached"],
                                  json: "{\"number\":42}"),
            in: directory)
        let recovered = try CLIIPCTransport.readResponse(id: id, in: directory)
        XCTAssertTrue(recovered.ok)
        XCTAssertEqual(recovered.warnings, ["#99 is not cached"])
        XCTAssertEqual(recovered.json, "{\"number\":42}")
    }

    func testFailureResponseCarriesCodeAndMessage() throws {
        let id = UUID()
        try CLIIPCTransport.write(response: CLIResponse(id: id, ok: false, errorCode: "auth",
                                                        errorMessage: "No GitHub token"),
                                  in: directory)
        let recovered = try CLIIPCTransport.readResponse(id: id, in: directory)
        XCTAssertFalse(recovered.ok)
        XCTAssertEqual(recovered.errorCode, "auth")
    }

    func testReadingAMissingResponseThrows() {
        XCTAssertThrowsError(try CLIIPCTransport.readResponse(id: UUID(), in: directory))
    }

    /// A long email body must survive — this is exactly why payloads are files rather than
    /// distributed-notification userInfo.
    func testLargePayloadSurvives() throws {
        let body = String(repeating: "Thanks for the detailed report. ", count: 2_000)
        let request = CLIRequest(kind: .respond, payload: ["body": body])
        try CLIIPCTransport.write(request: request, in: directory)
        XCTAssertEqual(try CLIIPCTransport.readRequest(id: request.id, in: directory).payload["body"],
                       body)
    }

    func testReadingConsumesTheFile() throws {
        let request = CLIRequest(kind: .refresh, payload: [:])
        try CLIIPCTransport.write(request: request, in: directory)
        _ = try CLIIPCTransport.readRequest(id: request.id, in: directory)
        XCTAssertThrowsError(try CLIIPCTransport.readRequest(id: request.id, in: directory),
                             "a consumed request must not be readable twice")

        // The claim is a rename, so the payload must not survive under the claimed name either —
        // otherwise the directory fills with unanswered requests nothing will ever reap early.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.contains(request.id.uuidString) }
        XCTAssertEqual(leftovers, [], "the claim file must be removed once the request is read")
    }

    /// Two app instances (installed build + Xcode dev build) wake on the same ping. If both
    /// could read the payload, a single `respond` would email the reporter twice; the atomic
    /// rename must let exactly one through.
    func testOnlyOneConcurrentReaderClaimsTheRequest() async throws {
        let request = CLIRequest(kind: .respond, payload: ["body": "Thanks for the report."])
        try CLIIPCTransport.write(request: request, in: directory)
        let id = request.id
        let directory = self.directory!

        var claims = 0
        await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    (try? CLIIPCTransport.readRequest(id: id, in: directory)) != nil
                }
            }
            for await claimed in group where claimed { claims += 1 }
        }
        XCTAssertEqual(claims, 1, "exactly one reader may consume a request")
    }

    /// The claim decides the winner, so two instances must never aim at the same destination.
    func testClaimPathIsPerProcessAndDistinctFromTheRequestPath() {
        let id = UUID()
        let mine = CLIIPCTransport.claimURL(id: id, in: directory, pid: 111)
        let theirs = CLIIPCTransport.claimURL(id: id, in: directory, pid: 222)
        XCTAssertNotEqual(mine, theirs)
        XCTAssertNotEqual(mine, CLIIPCTransport.requestURL(id: id, in: directory))
        XCTAssertTrue(mine.lastPathComponent.contains("claim-111"))
    }

    /// An instance that died between claiming and replying leaves the payload under its claim
    /// name; `rename` preserves the modification date, so the sweep must still reap it.
    func testSweepReapsAClaimLeftBehindByACrashedInstance() throws {
        let request = CLIRequest(kind: .respond, payload: [:])
        try CLIIPCTransport.write(request: request, in: directory)
        let claimed = CLIIPCTransport.claimURL(id: request.id, in: directory, pid: 4242)
        try FileManager.default.moveItem(
            at: CLIIPCTransport.requestURL(id: request.id, in: directory), to: claimed)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -7200)],
                                              ofItemAtPath: claimed.path)

        CLIIPCTransport.sweep(in: directory, olderThan: 3600)
        XCTAssertFalse(FileManager.default.fileExists(atPath: claimed.path))
    }

    /// ...but a claim made moments ago belongs to a request still being answered.
    func testSweepLeavesAFreshClaimAlone() throws {
        let request = CLIRequest(kind: .respond, payload: [:])
        try CLIIPCTransport.write(request: request, in: directory)
        let claimed = CLIIPCTransport.claimURL(id: request.id, in: directory, pid: 4242)
        try FileManager.default.moveItem(
            at: CLIIPCTransport.requestURL(id: request.id, in: directory), to: claimed)

        CLIIPCTransport.sweep(in: directory, olderThan: 3600)
        XCTAssertTrue(FileManager.default.fileExists(atPath: claimed.path),
                      "an in-flight request must not be swept out from under the responder")
    }

    func testSweepRemovesStaleFilesOnly() throws {
        let old = CLIRequest(kind: .refresh, payload: [:])
        let fresh = CLIRequest(kind: .refresh, payload: [:])
        try CLIIPCTransport.write(request: old, in: directory)
        try CLIIPCTransport.write(request: fresh, in: directory)

        let oldPath = CLIIPCTransport.requestURL(id: old.id, in: directory)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -7200)],
                                              ofItemAtPath: oldPath.path)
        CLIIPCTransport.sweep(in: directory, olderThan: 3600)

        XCTAssertFalse(FileManager.default.fileExists(atPath: oldPath.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: CLIIPCTransport.requestURL(id: fresh.id, in: directory).path))
    }

    func testDefaultDirectoryIsUnderApplicationSupport() {
        XCTAssertTrue(CLIIPCTransport.directory.path.contains("Application Support"))
        XCTAssertEqual(CLIIPCTransport.directory.lastPathComponent, "cli-ipc")
    }

    func testNotificationNamesAreDistinctAndBranded() {
        XCTAssertNotEqual(CLIBranding.requestNotification, CLIBranding.responseNotification)
        XCTAssertTrue(CLIBranding.requestNotification.hasPrefix("com.amirhayek.AppFeedback.cli"))
    }
}

final class CLIRequestResponderTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL.temporaryDirectory.appending(path: "cliresp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    @MainActor
    func testResponderRunsTheHandlerAndWritesASuccessResponse() async throws {
        let request = CLIRequest(kind: .refresh, payload: ["productID": UUID().uuidString])
        try CLIIPCTransport.write(request: request, in: directory)

        let responder = CLIRequestResponder(directory: directory) { received in
            XCTAssertEqual(received.kind, .refresh)
            return CLIResponse(id: received.id, ok: true, json: "{\"refreshed\":true}")
        }
        await responder.handle(requestID: request.id)

        let response = try CLIIPCTransport.readResponse(id: request.id, in: directory)
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.json, "{\"refreshed\":true}")
    }

    @MainActor
    func testResponderTurnsACLIErrorIntoATypedFailureResponse() async throws {
        let request = CLIRequest(kind: .createTask, payload: [:])
        try CLIIPCTransport.write(request: request, in: directory)

        let responder = CLIRequestResponder(directory: directory) { _ in
            throw CLIError.auth(message: "No GitHub token", hint: "Re-authenticate")
        }
        await responder.handle(requestID: request.id)

        let response = try CLIIPCTransport.readResponse(id: request.id, in: directory)
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.errorCode, "auth")
        XCTAssertEqual(response.errorHint, "Re-authenticate")
    }

    @MainActor
    func testResponderTurnsAnUnknownErrorIntoAFailureResponse() async throws {
        struct Boom: Error {}
        let request = CLIRequest(kind: .createTask, payload: [:])
        try CLIIPCTransport.write(request: request, in: directory)

        let responder = CLIRequestResponder(directory: directory) { _ in throw Boom() }
        await responder.handle(requestID: request.id)

        let response = try CLIIPCTransport.readResponse(id: request.id, in: directory)
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.errorCode, "remote_failure")
        XCTAssertNotNil(response.errorMessage)
    }

    @MainActor
    func testResponderIgnoresAnUnknownRequestIDWithoutCrashing() async {
        let responder = CLIRequestResponder(directory: directory) { _ in
            XCTFail("handler must not run for a missing request")
            return CLIResponse(id: UUID(), ok: true)
        }
        await responder.handle(requestID: UUID())
    }

    /// Both the installed app and an Xcode build observe the same notification name, so the
    /// responder can be asked to handle one id more than once. The handler — which sends the
    /// email — must run exactly once.
    @MainActor
    func testResponderRunsTheHandlerOnlyOncePerRequest() async throws {
        final class Box: @unchecked Sendable { var runs = 0 }
        let box = Box()
        let request = CLIRequest(kind: .respond, payload: ["body": "Thanks!"])
        try CLIIPCTransport.write(request: request, in: directory)

        let responder = CLIRequestResponder(directory: directory) { received in
            box.runs += 1
            return CLIResponse(id: received.id, ok: true)
        }
        await responder.handle(requestID: request.id)
        _ = try CLIIPCTransport.readResponse(id: request.id, in: directory)   // the CLI collects it
        await responder.handle(requestID: request.id)

        XCTAssertEqual(box.runs, 1, "a request must be executed exactly once")
        XCTAssertThrowsError(try CLIIPCTransport.readResponse(id: request.id, in: directory),
                             "the second pass must not have written a second response")
    }

    /// AppKit suspends distributed-notification delivery while the app is inactive — which it
    /// always is when an agent drives a terminal. Without .deliverImmediately every request
    /// would hang until the app next came forward. Only the selector-based registration API
    /// accepts a suspension behavior, which is why the responder uses it.
    func testResponderRegistersForImmediateDelivery() {
        XCTAssertEqual(CLIRequestResponder.suspensionBehavior, .deliverImmediately)
    }

    func testClientReportsAppNotRunningWhenTheBundleIsAbsent() {
        XCTAssertFalse(CLIRequestClient.isAppRunning(bundleIdentifier: "com.example.not.running"))
    }

    /// The test host runs inside AppFeedback.app, so the liveness probe finds *itself* — which
    /// is the correct answer for that bundle id. Whether `send` then times out or gets a real
    /// reply depends on whether the GUI is up, so that path is verified live, not here.
    func testLivenessProbeFindsTheHostBundle() {
        XCTAssertTrue(CLIRequestClient.isAppRunning(bundleIdentifier: CLIBranding.bundleIdentifier),
                      "the XCTest host is the app bundle, so its own id must read as running")
    }
}
#endif
