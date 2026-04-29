import Foundation

/// Actor that schedules IMAP polls, drives one-time backfill, writes through `MailThreadStore`,
/// and logs activity to `ActivityLog`.
actor MailSyncCoordinator {

    // MARK: - Status

    enum Status: Equatable, Sendable {
        case idle
        case polling
        case authFailed(message: String)
        case transient(error: String)
    }

    // MARK: - Value-type snapshot of the data we need from MainActor

    private struct AccountSnapshot: Sendable {
        let id: UUID
        let pollIntervalSeconds: Int
        let pollingEnabled: Bool
        let backfillCompleted: Bool
    }

    private struct LocalStateSnapshot: Sendable {
        let inboxLastUID: UInt32
        let consecutiveFailures: Int
    }

    // MARK: - Dependencies

    private let client: IMAPClientProtocol
    private let threadStore: MailThreadStore           // @MainActor
    private let accountStore: MailAccountStore         // @MainActor
    private let localState: MailAccountLocalStateStore // @MainActor
    private let activityLog: ActivityLog               // @MainActor
    private let knownIssueTitlesProvider: @Sendable () async -> [(owner: String, repo: String, number: Int, title: String)]
    private let clock: @Sendable () -> Date

    // MARK: - Internal state

    private(set) var status: Status = .idle
    private var inFlight: Bool = false
    private var loopTask: Task<Void, Never>?

    // MARK: - Init

    init(
        client: IMAPClientProtocol,
        threadStore: MailThreadStore,
        accountStore: MailAccountStore,
        localState: MailAccountLocalStateStore,
        activityLog: ActivityLog,
        knownIssueTitlesProvider: @Sendable @escaping () async -> [(owner: String, repo: String, number: Int, title: String)],
        clock: @Sendable @escaping () -> Date = { Date() }
    ) {
        self.client = client
        self.threadStore = threadStore
        self.accountStore = accountStore
        self.localState = localState
        self.activityLog = activityLog
        self.knownIssueTitlesProvider = knownIssueTitlesProvider
        self.clock = clock
    }

    // MARK: - Public API

    /// Starts the polling loop. Cancels any prior loop first.
    func start() {
        loopTask?.cancel()
        loopTask = Task {
            // Immediate launch poll
            guard !Task.isCancelled else { return }
            await pollOnce()

            // Interval loop
            while !Task.isCancelled {
                // Read the current poll settings as a value snapshot
                let snapshot = await MainActor.run { () -> (intervalSeconds: Int, pollingEnabled: Bool, consecutiveFailures: Int) in
                    let account = self.accountStore.account
                    let failures = self.localState.state?.consecutiveFailures ?? 0
                    return (
                        account?.pollIntervalSeconds ?? 300,
                        account?.pollingEnabled ?? true,
                        failures
                    )
                }

                // If polling is disabled, sleep 60s and recheck
                let baseSeconds = snapshot.pollingEnabled ? snapshot.intervalSeconds : 60

                // Apply exponential backoff for transient failures
                let sleepSeconds: Int
                if snapshot.consecutiveFailures > 0 {
                    sleepSeconds = min(baseSeconds, Int(30.0 * pow(2.0, Double(snapshot.consecutiveFailures - 1))))
                } else {
                    sleepSeconds = baseSeconds
                }

                let ns = UInt64(sleepSeconds) * 1_000_000_000
                try? await Task.sleep(nanoseconds: ns)

                guard !Task.isCancelled else { return }
                await pollOnce()
            }
        }
    }

    /// Manual/scenePhase-triggered poll. Coalesced if a poll is already in flight.
    func pollNow() async {
        guard !inFlight else { return }
        await pollOnce()
    }

    /// Halts the polling loop and resets status to idle.
    func stop() {
        loopTask?.cancel()
        loopTask = nil
        status = .idle
    }

    // MARK: - Private

    /// The workhorse: performs one full poll cycle (inbox fetch + optional backfill).
    private func pollOnce() async {
        guard !inFlight else { return }
        inFlight = true
        defer { inFlight = false }

        // 1. Read account and local state as value-type snapshots (single MainActor hop)
        let accountSnapshot = await MainActor.run { () -> AccountSnapshot? in
            guard let acc = self.accountStore.account else { return nil }
            return AccountSnapshot(
                id: acc.id,
                pollIntervalSeconds: acc.pollIntervalSeconds,
                pollingEnabled: acc.pollingEnabled,
                backfillCompleted: acc.backfillCompleted
            )
        }
        guard let accountSnapshot else {
            status = .idle
            return
        }

        // 2. Read local state snapshot
        let localSnapshot = await MainActor.run { () -> LocalStateSnapshot in
            let ls = self.localState.ensure(accountID: accountSnapshot.id)
            return LocalStateSnapshot(
                inboxLastUID: ls.inboxLastUID,
                consecutiveFailures: ls.consecutiveFailures
            )
        }

        // 3. Set status to .polling and log start
        status = .polling
        let logID = await MainActor.run {
            self.activityLog.start(kind: .fetchMail, title: "Fetch mail")
        }

        // 4. Fetch inbox
        do {
            let messages = try await client.listInbox(sinceUID: localSnapshot.inboxLastUID)

            // Hand each message to the thread store on MainActor
            await MainActor.run {
                for msg in messages {
                    self.threadStore.recordInbound(message: msg)
                }
            }

            // Compute highest UID
            let maxUID = messages.map(\.uid).max() ?? localSnapshot.inboxLastUID
            let now = clock()

            // Persist new cursor and reset failure count (before setting status)
            await MainActor.run {
                self.localState.update { ls in
                    if maxUID > ls.inboxLastUID {
                        ls.inboxLastUID = maxUID
                    }
                    ls.lastSuccessfulPollAt = now
                    ls.consecutiveFailures = 0
                }
            }

            status = .idle
            await MainActor.run {
                self.activityLog.finish(logID, status: .success, detail: "\(messages.count) message(s)")
            }

            // 5. Backfill (only if not yet completed and inbox fetch succeeded)
            if !accountSnapshot.backfillCompleted {
                await runBackfill(accountID: accountSnapshot.id)
            }

        } catch IMAPClientError.authFailed {
            status = .authFailed(message: "IMAP login failed — re-enter password")
            await MainActor.run {
                self.activityLog.finish(logID, status: .failure, detail: "Authentication failed")
            }
            // Stop the loop — auth requires user intervention
            loopTask?.cancel()
            loopTask = nil

        } catch {
            let errorMessage = error.localizedDescription
            status = .transient(error: errorMessage)
            await MainActor.run {
                self.localState.update { ls in
                    ls.consecutiveFailures += 1
                }
                self.activityLog.finish(logID, status: .failure, detail: errorMessage)
            }
        }
    }

    /// Performs the one-time backfill of the Sent folder.
    private func runBackfill(accountID: UUID) async {
        let oneYearAgo = Date(timeIntervalSinceNow: -365 * 24 * 3600)
        let backfillLogID = await MainActor.run {
            self.activityLog.start(kind: .fetchMail, title: "Backfill sent folder")
        }

        do {
            let sentMessages = try await client.listSent(sinceDate: oneYearAgo)
            let knownTitles = await knownIssueTitlesProvider()

            await MainActor.run {
                for msg in sentMessages {
                    let match = ThreadMatcher.matchToIssue(
                        threadSubject: msg.subject,
                        knownIssueTitles: knownTitles
                    )
                    let repoOwner = match?.owner ?? ""
                    let repoName = match?.repo ?? ""
                    let issueNumber = match?.number ?? 0

                    self.threadStore.recordOutbound(
                        messageID: msg.messageID,
                        repoOwner: repoOwner,
                        repoName: repoName,
                        issueNumber: issueNumber,
                        from: msg.fromAddress,
                        fromName: msg.fromName,
                        to: msg.toAddresses,
                        cc: msg.ccAddresses,
                        subject: msg.subject,
                        bodyPlain: msg.bodyPlain,
                        bodyHTML: msg.bodyHTML,
                        date: msg.date,
                        replyHeaders: nil
                    )
                }

                // Flip backfillCompleted
                self.accountStore.upsert { acc in
                    acc.backfillCompleted = true
                }
                self.activityLog.finish(backfillLogID, status: .success, detail: "\(sentMessages.count) sent message(s) backfilled")
            }

        } catch {
            await MainActor.run {
                self.activityLog.finish(backfillLogID, status: .failure, detail: error.localizedDescription)
            }
            // Do NOT flip backfillCompleted — next poll will retry
        }
    }
}
