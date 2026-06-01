import XCTest
import SwiftData
@testable import AppFeedback

// MARK: - MockIMAPClient

final class MockIMAPClient: IMAPClientProtocol, @unchecked Sendable {
    var inboxResponses: [Result<[ParsedInboundMessage], Error>] = []
    var sentResponses: [Result<[ParsedInboundMessage], Error>] = []
    var sentEnrichmentResponses: [Result<[ParsedInboundMessage], Error>] = []
    var inboxCallCount = 0
    var sentCallCount = 0
    var sentEnrichmentCallCount = 0
    /// Captures the messageIDs gate passed on the most recent enrichment call so tests can
    /// assert it was driven by `outboundNeedingEnrichment`.
    var lastEnrichMessageIDs: Set<String> = []

    func listInbox(sinceUID: UInt32, expectedUIDValidity: UInt32, fromAddresses: [String]) async throws -> InboxPollResult {
        inboxCallCount += 1
        guard !inboxResponses.isEmpty else { return InboxPollResult(messages: [], uidValidity: 0) }
        let result = inboxResponses.removeFirst()
        switch result {
        case .success(let msgs): return InboxPollResult(messages: msgs, uidValidity: 0)
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

    func listSentForEnrichment(sinceDate: Date, messageIDs: Set<String>) async throws -> [ParsedInboundMessage] {
        sentEnrichmentCallCount += 1
        lastEnrichMessageIDs = messageIDs
        guard !sentEnrichmentResponses.isEmpty else { return [] }
        let result = sentEnrichmentResponses.removeFirst()
        switch result {
        case .success(let msgs): return msgs
        case .failure(let err): throw err
        }
    }

    func fetchAttachmentBytes(uid: UInt32, folder: String, partID: String, expectedUIDValidity: UInt32) async throws -> Data {
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
                MailSettings.self,
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
        let settingsStore = MailSettingsStore(context: context)
        let localStateStore = MailAccountLocalStateStore(context: context)
        let activityLog = ActivityLog(persistenceURL: nil)

        // Insert a test account
        _ = accountStore.add { acc in
            acc.pollingEnabled = true
            acc.backfillCompleted = backfillCompleted
        }
        let accountID = accountStore.accounts.first!.id

        let coordinator = MailSyncCoordinator(
            client: mock,
            accountID: accountID,
            threadStore: threadStore,
            accountStore: accountStore,
            settingsStore: settingsStore,
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
        let accountIDOptional = await MainActor.run { self.accountStore(in: context)?.id }
        let accountID = try XCTUnwrap(accountIDOptional)
        _ = localStateStore.ensure(accountID: accountID)

        await coordinator.pollNow()

        let status = await coordinator.status
        XCTAssertEqual(status, .authFailed(message: "IMAP login failed — re-enter password"))

        // consecutiveFailures should NOT be incremented by auth failures
        let failures = localStateStore.state(accountID: accountID)?.consecutiveFailures ?? 0
        XCTAssertEqual(failures, 0, "Auth failure should not increment consecutiveFailures")
    }

    // MARK: - Test 3: pollNow while poll in flight is coalesced

    func test_pollNow_whilePollInFlight_isCoalesced() async throws {
        let context = try makeContext()
        let slowMock = SlowMockIMAPClient()

        let threadStore = MailThreadStore(context: context)
        let accountStore = MailAccountStore(context: context)
        let settingsStore = MailSettingsStore(context: context)
        let localStateStore = MailAccountLocalStateStore(context: context)
        let activityLog = ActivityLog(persistenceURL: nil)

        _ = accountStore.add { acc in
            acc.pollingEnabled = true
            acc.backfillCompleted = true
        }
        let accountID = accountStore.accounts.first!.id

        let coordinator = MailSyncCoordinator(
            client: slowMock,
            accountID: accountID,
            threadStore: threadStore,
            accountStore: accountStore,
            settingsStore: settingsStore,
            localState: localStateStore,
            activityLog: activityLog,
            knownIssueTitlesProvider: { [] }
        )

        // Start the first poll — it will block inside listInbox at the gate.
        async let first: Void = coordinator.pollNow()
        // Wait until the first call has entered listInbox and is parked at the gate.
        await slowMock.waitForFirstEntry()
        // Fire the second poll — coordinator sees inFlight == true and returns immediately.
        async let second: Void = coordinator.pollNow()
        _ = await second              // returns without calling listInbox
        await slowMock.unblock()      // release the first call
        _ = await first

        let count = await slowMock.inboxCallCount
        XCTAssertEqual(count, 1, "Second pollNow should be coalesced when inFlight is true")
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

        XCTAssertEqual(accountStore.accounts.first?.backfillCompleted, false, "Precondition")

        await coordinator.pollNow()

        XCTAssertEqual(accountStore.accounts.first?.backfillCompleted, true, "backfillCompleted should flip to true")
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

        XCTAssertEqual(accountStore.accounts.first?.backfillCompleted, false, "Precondition")

        await coordinator.pollNow()

        XCTAssertEqual(accountStore.accounts.first?.backfillCompleted, false, "backfillCompleted should stay false on sent error")
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

        let accountID = accountStore.accounts.first!.id
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
        let accountID = accountStore.accounts.first!.id
        _ = localStateStore.ensure(accountID: accountID)

        await coordinator.pollNow()

        let status = await coordinator.status
        if case .transient = status {
            // good
        } else {
            XCTFail("Expected .transient status, got \(status)")
        }

        let failures = localStateStore.state(accountID: accountID)?.consecutiveFailures ?? 0
        XCTAssertEqual(failures, 1, "consecutiveFailures should be 1 after first transient error")
    }

    // MARK: - Test 8: backoff is clamped and never overflows Int

    /// Regression: `backoffSeconds` computed `Int(30.0 * pow(2.0, failures - 1))` *before*
    /// clamping with `min(baseSeconds, …)`, so once an account reached ~60 consecutive
    /// failures the Double exceeded `Int.max` and the conversion trapped, crashing the app a
    /// few seconds after launch (during the first post-poll backoff calculation).
    func test_backoffSeconds_clampsToBase_andDoesNotOverflowAtHighFailureCounts() {
        // failures == 0 → no backoff, use the base interval
        XCTAssertEqual(MailSyncCoordinator.backoffSeconds(baseSeconds: 300, consecutiveFailures: 0), 300)

        // Early failures retry sooner than base, ramping up exponentially…
        XCTAssertEqual(MailSyncCoordinator.backoffSeconds(baseSeconds: 300, consecutiveFailures: 1), 30)
        XCTAssertEqual(MailSyncCoordinator.backoffSeconds(baseSeconds: 300, consecutiveFailures: 2), 60)
        XCTAssertEqual(MailSyncCoordinator.backoffSeconds(baseSeconds: 300, consecutiveFailures: 3), 120)

        // …but never longer than the configured base interval.
        XCTAssertEqual(MailSyncCoordinator.backoffSeconds(baseSeconds: 300, consecutiveFailures: 5), 300)
        XCTAssertEqual(MailSyncCoordinator.backoffSeconds(baseSeconds: 60, consecutiveFailures: 4), 60)

        // The crash case: a huge exponent overflows Int.max. Must clamp to base, not trap.
        XCTAssertEqual(MailSyncCoordinator.backoffSeconds(baseSeconds: 300, consecutiveFailures: 70), 300)
        XCTAssertEqual(MailSyncCoordinator.backoffSeconds(baseSeconds: 300, consecutiveFailures: 1000), 300)
    }

    // MARK: - Test 9: Sent enrichment upgrades the matching outbound row by Message-Id

    @discardableResult
    private func recordReply(_ store: MailThreadStore, _ messageID: String, accountID: UUID) -> MailMessage {
        let m = store.recordOutbound(
            messageID: messageID,
            repoOwner: "o", repoName: "r", issueNumber: 7,
            from: "me@example.com", fromName: "Me",
            to: ["user@example.com"], cc: [],
            subject: "Re: thing", bodyPlain: "see image", bodyHTML: nil,
            date: Date(),
            accountID: accountID,   // gate is account-scoped, so the row must carry the poller's account
            replyHeaders: nil
        )
        m.sentAt = Date()   // the real send sets this on success; the gate requires it
        return m
    }

    private func sentCopy(_ messageID: String, uid: UInt32, attachments: [ParsedAttachmentMeta]) -> ParsedInboundMessage {
        ParsedInboundMessage(
            uid: uid, folder: "[Gmail]/Sent Mail", uidValidity: 100,
            messageID: messageID, inReplyTo: nil, references: [],
            fromAddress: "me@example.com", fromName: nil,
            toAddresses: ["user@example.com"], ccAddresses: [],
            date: Date(), subject: "Re: thing", bodyPlain: "", bodyHTML: nil,
            attachments: attachments
        )
    }

    private func fetch(_ context: ModelContext, _ messageID: String) throws -> MailMessage? {
        try context.fetch(FetchDescriptor<MailMessage>(predicate: #Predicate { $0.messageID == messageID })).first
    }

    func test_sentEnrichment_upgradesOutboundRow() async throws {
        let context = try makeContext()
        let mock = MockIMAPClient()
        let env = makeCoordinator(mock: mock, context: context)
        let mid = "<af~o~r~7~deadbeef@app-feedback.local>"
        recordReply(env.threadStore, mid, accountID: env.accountStore.accounts.first!.id)
        let copy = sentCopy(mid, uid: 10, attachments: [
            ParsedAttachmentMeta(partID: "2", filename: "shot.png", mimeType: "image/png", sizeBytes: 1024, contentID: "<cid@x>")
        ])
        mock.sentEnrichmentResponses = [.success([copy])]

        await env.coordinator.pollNow()

        let msg = try XCTUnwrap(fetch(context, mid))
        XCTAssertEqual(msg.uid, 10)
        XCTAssertEqual(msg.folder, "[Gmail]/Sent Mail")
        XCTAssertEqual(msg.uidValidity, 100, "enrichment stamps the Sent folder's UIDVALIDITY for stale-uid detection")
        XCTAssertEqual((msg.attachments ?? []).count, 1)
        XCTAssertTrue(mock.lastEnrichMessageIDs.contains(mid), "enrichment must be gated by outboundNeedingEnrichment")
    }

    // MARK: - Test 10: steady state skips the Sent folder once nothing needs enriching

    func test_sentEnrichment_skipsSentFolder_onceNothingNeedsEnrichment() async throws {
        let context = try makeContext()
        let mock = MockIMAPClient()
        let env = makeCoordinator(mock: mock, context: context)
        let mid = "<af~o~r~7~beef@app-feedback.local>"
        recordReply(env.threadStore, mid, accountID: env.accountStore.accounts.first!.id)
        let copy = sentCopy(mid, uid: 10, attachments: [
            ParsedAttachmentMeta(partID: "2", filename: "s.png", mimeType: "image/png", sizeBytes: 1, contentID: "<c@x>")
        ])
        mock.sentEnrichmentResponses = [.success([copy])]

        await env.coordinator.pollNow()   // enriches; now nothing needs enrichment
        await env.coordinator.pollNow()   // must skip the Sent folder entirely

        XCTAssertEqual(mock.sentEnrichmentCallCount, 1, "Once enriched, the Sent folder must not be scanned again")
        XCTAssertEqual((try fetch(context, mid)?.attachments ?? []).count, 1, "No duplicate attachment rows across polls")
    }

    // MARK: - Test 11: a Sent-enrichment failure is isolated from the inbox poll

    func test_sentEnrichment_errorIsIsolated_fromInboxPoll() async throws {
        struct SentError: Error {}
        let context = try makeContext()
        let mock = MockIMAPClient()
        let env = makeCoordinator(mock: mock, context: context)
        let mid = "<af~o~r~7~err@app-feedback.local>"
        recordReply(env.threadStore, mid, accountID: env.accountStore.accounts.first!.id)
        mock.sentEnrichmentResponses = [.failure(SentError())]

        await env.coordinator.pollNow()

        let accountID = env.accountStore.accounts.first!.id
        let ls = try XCTUnwrap(env.localStateStore.state(accountID: accountID))
        XCTAssertEqual(ls.consecutiveFailures, 0, "A Sent-enrichment failure must not count against the inbox poll")
        XCTAssertEqual(try fetch(context, mid)?.uid, 0, "Message must remain un-enriched after a Sent fetch failure")
        let status = await env.coordinator.status
        XCTAssertEqual(status, .idle, "Inbox poll succeeded, so the coordinator stays idle despite the Sent error")
    }

    // MARK: - Test 12: a non-empty gate that finds nothing still does the scan but enriches nothing

    func test_sentEnrichment_unproductivePoll_enrichesNothing() async throws {
        let context = try makeContext()
        let mock = MockIMAPClient()
        let env = makeCoordinator(mock: mock, context: context)
        let mid = "<af~o~r~7~notfiled@app-feedback.local>"
        recordReply(env.threadStore, mid, accountID: env.accountStore.accounts.first!.id)
        // Gate is non-empty (recent, sent, uid==0) but the Sent copy isn't filed yet → no match.
        mock.sentEnrichmentResponses = [.success([])]

        await env.coordinator.pollNow()

        XCTAssertEqual(mock.sentEnrichmentCallCount, 1, "Gate was non-empty, so the Sent folder was scanned")
        XCTAssertEqual(try fetch(context, mid)?.uid, 0, "An unfound reply stays un-enriched and is retried next pass")
        // Version stability across an unproductive batch is asserted deterministically at the store
        // level in MailThreadStoreTests.test_withBatch_noOpDoesNotBumpVersion (free of the async
        // NSPersistentStoreRemoteChange bumps that a coordinator-level poll would introduce).
    }

    // MARK: - Test 13: cancelled passes must not exhaust the enrichment attempt cap

    func test_sentEnrichment_cancellationDoesNotStrandReply() async throws {
        let context = try makeContext()
        let mock = MockIMAPClient()
        let env = makeCoordinator(mock: mock, context: context)
        let mid = "<af~o~r~7~cancel@app-feedback.local>"
        recordReply(env.threadStore, mid, accountID: env.accountStore.accounts.first!.id)
        let copy = sentCopy(mid, uid: 10, attachments: [
            ParsedAttachmentMeta(partID: "2", filename: "s.png", mimeType: "image/png", sizeBytes: 1, contentID: "<c@x>")
        ])
        // Five cancelled passes (stop / account switch / teardown), then a clean one. Cancellations
        // must NOT count toward maxEnrichmentAttempts(=5), or the reply would be stranded for the
        // session and its attachment would never surface.
        mock.sentEnrichmentResponses = [
            .failure(IMAPClientError.cancelled), .failure(IMAPClientError.cancelled),
            .failure(IMAPClientError.cancelled), .failure(IMAPClientError.cancelled),
            .failure(IMAPClientError.cancelled), .success([copy]),
        ]

        for _ in 0..<6 { await env.coordinator.pollNow() }

        XCTAssertEqual(mock.sentEnrichmentCallCount, 6, "Cancellations must not exhaust the cap; the reply is still scanned")
        XCTAssertEqual(try fetch(context, mid)?.uid, 10, "The reply enriches once a poll completes uncancelled")
    }

    // MARK: - Helpers

    private func accountStore(in context: ModelContext) -> MailAccount? {
        var descriptor = FetchDescriptor<MailAccount>()
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }
}

// MARK: - SlowMockIMAPClient

/// A deterministic mock that parks `listInbox` at a `CheckedContinuation` gate,
/// letting the test control exactly when the call resumes. This avoids the
/// scheduler-dependent `Task.yield()` approach.
actor SlowMockIMAPClient: IMAPClientProtocol {
    private(set) var inboxCallCount = 0

    /// Gate that blocks listInbox until `unblock()` is called.
    private var gate: CheckedContinuation<Void, Never>?
    /// Continuation that fires once `listInbox` has incremented the counter and parked.
    private var entered: CheckedContinuation<Void, Never>?

    /// Suspends until `listInbox` has been entered and is waiting at the gate.
    func waitForFirstEntry() async {
        await withCheckedContinuation { cont in
            if inboxCallCount > 0 {
                cont.resume()
            } else {
                self.entered = cont
            }
        }
    }

    /// Releases the gate so that the blocked `listInbox` call can return.
    func unblock() {
        gate?.resume()
        gate = nil
    }

    func listInbox(sinceUID: UInt32, expectedUIDValidity: UInt32, fromAddresses: [String]) async throws -> InboxPollResult {
        inboxCallCount += 1
        entered?.resume()
        entered = nil
        await withCheckedContinuation { cont in self.gate = cont }
        return InboxPollResult(messages: [], uidValidity: 0)
    }

    func listSent(sinceDate: Date) async throws -> [ParsedInboundMessage] { [] }
    func listSentForEnrichment(sinceDate: Date, messageIDs: Set<String>) async throws -> [ParsedInboundMessage] { [] }
    func fetchAttachmentBytes(uid: UInt32, folder: String, partID: String, expectedUIDValidity: UInt32) async throws -> Data { Data() }
    func testConnection() async throws { }
}
