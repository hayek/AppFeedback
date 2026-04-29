import XCTest
import SwiftData
@testable import AppFeedback

// MARK: - MockIMAPClient

final class MockIMAPClient: IMAPClientProtocol, @unchecked Sendable {
    var inboxResponses: [Result<[ParsedInboundMessage], Error>] = []
    var sentResponses: [Result<[ParsedInboundMessage], Error>] = []
    var inboxCallCount = 0
    var sentCallCount = 0

    func listInbox(sinceUID: UInt32) async throws -> [ParsedInboundMessage] {
        inboxCallCount += 1
        guard !inboxResponses.isEmpty else { return [] }
        let result = inboxResponses.removeFirst()
        switch result {
        case .success(let msgs): return msgs
        case .failure(let err): throw err
        }
    }

    func listSent(sinceDate: Date) async throws -> [ParsedInboundMessage] {
        sentCallCount += 1
        guard !sentResponses.isEmpty else { return [] }
        let result = sentResponses.removeFirst()
        switch result {
        case .success(let msgs): return msgs
        case .failure(let err): throw err
        }
    }

    func fetchAttachmentBytes(uid: UInt32, folder: String, partID: String) async throws -> Data {
        Data()
    }

    func testConnection() async throws { }
}

// MARK: - MailSyncCoordinatorTests

@MainActor
final class MailSyncCoordinatorTests: XCTestCase {

    // MARK: Helpers

    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(
            for: MailThread.self, MailMessage.self, MailAttachment.self,
                MailAttachmentLocal.self, MailAccountLocalState.self, MailAccount.self,
            configurations: config
        )
        return ModelContext(container)
    }

    private func makeParsed(
        uid: UInt32 = 1,
        messageID: String = "<msg@example.com>",
        from: String = "sender@example.com",
        to: [String] = ["to@example.com"],
        subject: String = "Test",
        date: Date = Date(),
        inReplyTo: String? = nil,
        references: [String] = []
    ) -> ParsedInboundMessage {
        ParsedInboundMessage(
            uid: uid,
            folder: "INBOX",
            uidValidity: 100,
            messageID: messageID,
            inReplyTo: inReplyTo,
            references: references,
            fromAddress: from,
            fromName: nil,
            toAddresses: to,
            ccAddresses: [],
            date: date,
            subject: subject,
            bodyPlain: "Body",
            bodyHTML: nil,
            attachments: []
        )
    }

    /// Sets up all stores + coordinator. Inserts a `MailAccount` so polling can proceed.
    private func makeCoordinator(
        mock: MockIMAPClient,
        context: ModelContext,
        backfillCompleted: Bool = true
    ) -> (
        coordinator: MailSyncCoordinator,
        threadStore: MailThreadStore,
        accountStore: MailAccountStore,
        localStateStore: MailAccountLocalStateStore,
        activityLog: ActivityLog
    ) {
        let threadStore = MailThreadStore(context: context)
        let accountStore = MailAccountStore(context: context)
        let localStateStore = MailAccountLocalStateStore(context: context)
        let activityLog = ActivityLog(persistenceURL: nil)

        // Insert a test account
        accountStore.upsert { acc in
            acc.pollingEnabled = true
            acc.pollIntervalSeconds = 300
            acc.backfillCompleted = backfillCompleted
        }

        let coordinator = MailSyncCoordinator(
            client: mock,
            threadStore: threadStore,
            accountStore: accountStore,
            localState: localStateStore,
            activityLog: activityLog,
            knownIssueTitlesProvider: { [] },
            clock: { Date() }
        )

        return (coordinator, threadStore, accountStore, localStateStore, activityLog)
    }

    // MARK: - Test 1: Two polls returning same message dedupe via store

    func test_twoPolls_returningSameMessage_dedupesViaStore() async throws {
        let context = try makeContext()
        let mock = MockIMAPClient()
        let msg = makeParsed(uid: 1, messageID: "<dedup@example.com>")
        mock.inboxResponses = [.success([msg]), .success([msg])]

        let (coordinator, _, _, _, _) = makeCoordinator(mock: mock, context: context)

        // First poll
        await coordinator.pollNow()
        // Second poll — same message
        await coordinator.pollNow()

        let rows = try context.fetch(FetchDescriptor<MailMessage>())
        XCTAssertEqual(rows.count, 1, "Same messageID should be deduped — only one row")
    }

    // MARK: - Test 2: Auth error sets authFailed status and suspends backoff

    func test_authError_setsAuthFailedStatus_andSuspendsBackoff() async throws {
        let context = try makeContext()
        let mock = MockIMAPClient()
        mock.inboxResponses = [.failure(IMAPClientError.authFailed)]

        let (coordinator, _, _, localStateStore, _) = makeCoordinator(mock: mock, context: context)

        // Ensure account is set up so localState can be read
        let accountID = await MainActor.run { self.accountStore(in: context)?.id } ?? UUID()
        _ = localStateStore.ensure(accountID: accountID)

        await coordinator.pollNow()

        let status = await coordinator.status
        XCTAssertEqual(status, .authFailed(message: "IMAP login failed — re-enter password"))

        // consecutiveFailures should NOT be incremented by auth failures
        let failures = localStateStore.state?.consecutiveFailures ?? 0
        XCTAssertEqual(failures, 0, "Auth failure should not increment consecutiveFailures")
    }

    // MARK: - Test 3: pollNow while poll in flight is coalesced

    func test_pollNow_whilePollInFlight_isCoalesced() async throws {
        let context = try makeContext()
        let mock = MockIMAPClient()

        // Use a slow response to ensure the first poll is still "in flight" when the second arrives.
        // In actor-sequential tests, we can't truly parallelise without tasks, so instead we use
        // the actor's inFlight flag by calling a second pollNow synchronously after the first has
        // set inFlight=true inside pollOnce. We do this by adding a small async hook.
        //
        // Practical approach: send two independent Tasks to pollNow and let actor serialisation
        // handle it. The mock returns two responses; we expect only one inbox call because the
        // second pollNow returns immediately when inFlight is true.

        // Use an actor-checked slow path: give the mock a successful response with a real delay.
        // Since actors are re-entrant on await, the second pollNow will observe inFlight == true
        // while the first is suspended inside client.listInbox.

        // Instrument the mock to introduce an artificial suspension
        let slowMock = SlowMockIMAPClient()
        slowMock.inboxResponses = [.success([makeParsed()]), .success([makeParsed(messageID: "<other@x.com>")])]

        let threadStore = MailThreadStore(context: context)
        let accountStore = MailAccountStore(context: context)
        let localStateStore = MailAccountLocalStateStore(context: context)
        let activityLog = ActivityLog(persistenceURL: nil)

        accountStore.upsert { acc in
            acc.pollingEnabled = true
            acc.pollIntervalSeconds = 300
            acc.backfillCompleted = true
        }

        let coordinator = MailSyncCoordinator(
            client: slowMock,
            threadStore: threadStore,
            accountStore: accountStore,
            localState: localStateStore,
            activityLog: activityLog,
            knownIssueTitlesProvider: { [] }
        )

        // Fire two pollNow calls concurrently
        async let first: Void = coordinator.pollNow()
        async let second: Void = coordinator.pollNow()
        _ = await (first, second)

        // Only 1 inbox call should have been made (second was coalesced)
        XCTAssertEqual(slowMock.inboxCallCount, 1, "Second pollNow should be coalesced when inFlight is true")
    }

    // MARK: - Test 4: backfillCompleted flips after first successful sent scan

    func test_backfillCompleted_flipsAfterFirstSuccessfulSentScan() async throws {
        let context = try makeContext()
        let mock = MockIMAPClient()
        mock.inboxResponses = [.success([])]
        mock.sentResponses = [.success([])]

        let (coordinator, _, accountStore, _, _) = makeCoordinator(
            mock: mock, context: context, backfillCompleted: false
        )

        XCTAssertEqual(accountStore.account?.backfillCompleted, false, "Precondition")

        await coordinator.pollNow()

        XCTAssertEqual(accountStore.account?.backfillCompleted, true, "backfillCompleted should flip to true")
    }

    // MARK: - Test 5: backfillCompleted does not flip on sent error

    func test_backfillCompleted_doesNotFlipOnSentError() async throws {
        let context = try makeContext()
        let mock = MockIMAPClient()
        mock.inboxResponses = [.success([])]
        mock.sentResponses = [.failure(IMAPClientError.transport(underlying: "network error"))]

        let (coordinator, _, accountStore, _, _) = makeCoordinator(
            mock: mock, context: context, backfillCompleted: false
        )

        XCTAssertEqual(accountStore.account?.backfillCompleted, false, "Precondition")

        await coordinator.pollNow()

        XCTAssertEqual(accountStore.account?.backfillCompleted, false, "backfillCompleted should stay false on sent error")
    }

    // MARK: - Test 6: inboxCursor advances to highest UID

    func test_inboxCursor_advancesToHighestUID() async throws {
        let context = try makeContext()
        let mock = MockIMAPClient()
        let messages = [
            makeParsed(uid: 5, messageID: "<msg5@x.com>"),
            makeParsed(uid: 12, messageID: "<msg12@x.com>"),
            makeParsed(uid: 8, messageID: "<msg8@x.com>")
        ]
        mock.inboxResponses = [.success(messages)]

        let (coordinator, _, accountStore, localStateStore, _) = makeCoordinator(mock: mock, context: context)

        await coordinator.pollNow()

        let accountID = accountStore.account!.id
        let ls = localStateStore.ensure(accountID: accountID)
        XCTAssertEqual(ls.inboxLastUID, 12, "Cursor should advance to the highest UID (12)")
    }

    // MARK: - Test 7: transient error increments consecutiveFailures

    func test_transientError_incrementsConsecutiveFailures() async throws {
        let context = try makeContext()
        let mock = MockIMAPClient()
        mock.inboxResponses = [.failure(IMAPClientError.transport(underlying: "timeout"))]

        let (coordinator, _, accountStore, localStateStore, _) = makeCoordinator(mock: mock, context: context)

        // Seed localState
        let accountID = accountStore.account!.id
        _ = localStateStore.ensure(accountID: accountID)

        await coordinator.pollNow()

        let status = await coordinator.status
        if case .transient = status {
            // good
        } else {
            XCTFail("Expected .transient status, got \(status)")
        }

        let failures = localStateStore.state?.consecutiveFailures ?? 0
        XCTAssertEqual(failures, 1, "consecutiveFailures should be 1 after first transient error")
    }

    // MARK: - Helpers

    private func accountStore(in context: ModelContext) -> MailAccount? {
        var descriptor = FetchDescriptor<MailAccount>()
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }
}

// MARK: - SlowMockIMAPClient

/// A mock that suspends briefly inside listInbox to allow actor re-entrancy tests.
final class SlowMockIMAPClient: IMAPClientProtocol, @unchecked Sendable {
    var inboxResponses: [Result<[ParsedInboundMessage], Error>] = []
    var sentResponses: [Result<[ParsedInboundMessage], Error>] = []
    var inboxCallCount = 0
    var sentCallCount = 0

    func listInbox(sinceUID: UInt32) async throws -> [ParsedInboundMessage] {
        inboxCallCount += 1
        // Minimal async suspension to allow other tasks to interleave
        await Task.yield()
        guard !inboxResponses.isEmpty else { return [] }
        let result = inboxResponses.removeFirst()
        switch result {
        case .success(let msgs): return msgs
        case .failure(let err): throw err
        }
    }

    func listSent(sinceDate: Date) async throws -> [ParsedInboundMessage] {
        sentCallCount += 1
        guard !sentResponses.isEmpty else { return [] }
        let result = sentResponses.removeFirst()
        switch result {
        case .success(let msgs): return msgs
        case .failure(let err): throw err
        }
    }

    func fetchAttachmentBytes(uid: UInt32, folder: String, partID: String) async throws -> Data { Data() }
    func testConnection() async throws { }
}
