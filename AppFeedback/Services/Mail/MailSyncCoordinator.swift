import Foundation
import Observation

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
        let inboxUIDValidity: UInt32
        let consecutiveFailures: Int
    }

    /// How far back Sent enrichment looks. Bounds both the server-side Message-Id search and the
    /// gate, so a reply whose Sent copy never appears stops forcing a scan once it ages out.
    private static let sentEnrichmentWindow: TimeInterval = 30 * 24 * 3600

    /// After this many consecutive failed enrichment attempts for a Message-Id this session, stop
    /// searching for it — its Sent copy isn't appearing (failed APPEND, no Sent folder, rewritten
    /// Message-Id). In-memory, so a relaunch retries a bounded number of times. Without this a
    /// stranded reply would force a Sent scan every poll for the whole 30-day window.
    private static let maxEnrichmentAttempts = 5

    // MARK: - Dependencies

    private let client: IMAPClientProtocol
    private let accountID: UUID
    private let threadStore: MailThreadStore           // @MainActor
    private let accountStore: MailAccountStore         // @MainActor
    private let settingsStore: MailSettingsStore       // @MainActor
    private let localState: MailAccountLocalStateStore // @MainActor
    private let activityLog: ActivityLog               // @MainActor
    private let mirror: MailToGitHubMirror?            // @MainActor
    private let notificationService: NotificationService? // @MainActor
    private let knownIssueTitlesProvider: @Sendable () async -> [(owner: String, repo: String, number: Int, title: String)]
    private let clock: @Sendable () -> Date

    // MARK: - Internal state

    private(set) var status: Status = .idle
    private var inFlight: Bool = false
    private var loopTask: Task<Void, Never>?
    /// Per-Message-Id consecutive failed-enrichment counts (in-memory, this session). See
    /// `maxEnrichmentAttempts`.
    private var enrichmentAttempts: [String: Int] = [:]

    // MARK: - Init

    init(
        client: IMAPClientProtocol,
        accountID: UUID,
        threadStore: MailThreadStore,
        accountStore: MailAccountStore,
        settingsStore: MailSettingsStore,
        localState: MailAccountLocalStateStore,
        activityLog: ActivityLog,
        mirror: MailToGitHubMirror? = nil,
        notificationService: NotificationService? = nil,
        knownIssueTitlesProvider: @Sendable @escaping () async -> [(owner: String, repo: String, number: Int, title: String)],
        clock: @Sendable @escaping () -> Date = { Date() }
    ) {
        self.client = client
        self.accountID = accountID
        self.threadStore = threadStore
        self.accountStore = accountStore
        self.settingsStore = settingsStore
        self.localState = localState
        self.activityLog = activityLog
        self.mirror = mirror
        self.notificationService = notificationService
        self.knownIssueTitlesProvider = knownIssueTitlesProvider
        self.clock = clock
    }

    // MARK: - Public API

    /// Seconds to wait before the next poll. On transient failure we retry *sooner* than the
    /// normal interval (starting at 30s) and ramp back up exponentially, capped at `baseSeconds`
    /// so we never wait longer than the configured poll cadence.
    static func backoffSeconds(baseSeconds: Int, consecutiveFailures: Int) -> Int {
        guard consecutiveFailures > 0 else { return baseSeconds }
        // Clamp in Double space *before* converting to Int. At ~60+ failures,
        // 30 · 2^(failures-1) exceeds Int.max and `Int(_:)` traps on the out-of-range
        // Double — which crashed the app a few seconds after launch. Taking the min
        // against Double(baseSeconds) keeps the value small and finite (even against
        // +inf), so the conversion is always safe. Result is identical to
        // min(baseSeconds, Int(backoff)) for every non-overflowing input.
        let backoff = 30.0 * pow(2.0, Double(consecutiveFailures - 1))
        return Int(min(Double(baseSeconds), backoff))
    }

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
                let accountID = self.accountID
                let snapshot = await MainActor.run { () -> (intervalSeconds: Int, pollingEnabled: Bool, consecutiveFailures: Int) in
                    let account = self.accountStore.account(id: accountID)
                    let failures = self.localState.state(accountID: accountID)?.consecutiveFailures ?? 0
                    return (
                        self.settingsStore.settings.pollIntervalSeconds,
                        account?.pollingEnabled ?? true,
                        failures
                    )
                }

                // If polling is disabled, sleep 60s and recheck
                let baseSeconds = snapshot.pollingEnabled ? snapshot.intervalSeconds : 60

                // Apply exponential backoff for transient failures
                let sleepSeconds = Self.backoffSeconds(
                    baseSeconds: baseSeconds,
                    consecutiveFailures: snapshot.consecutiveFailures
                )

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

        let accountID = self.accountID
        let accountSnapshot = await MainActor.run { () -> AccountSnapshot? in
            guard let acc = self.accountStore.account(id: accountID) else { return nil }
            return AccountSnapshot(
                id: acc.id,
                pollIntervalSeconds: self.settingsStore.settings.pollIntervalSeconds,
                pollingEnabled: acc.pollingEnabled,
                backfillCompleted: acc.backfillCompleted
            )
        }
        guard let accountSnapshot else {
            status = .idle
            return
        }

        let localSnapshot = await MainActor.run { () -> LocalStateSnapshot in
            let ls = self.localState.ensure(accountID: accountSnapshot.id)
            return LocalStateSnapshot(
                inboxLastUID: ls.inboxLastUID,
                inboxUIDValidity: ls.inboxUIDValidity,
                consecutiveFailures: ls.consecutiveFailures
            )
        }

        let accountLabel = await MainActor.run { accountStore.account(id: accountID)?.smtpUsername ?? "—" }
        status = .polling
        let logID = await MainActor.run {
            self.activityLog.start(kind: .fetchMail, title: "Fetch mail (\(accountLabel))")
        }

        // Backfill must run before listInbox: the inbox poll's FROM filter depends on
        // outbound recipients, and on a fresh install those only exist after backfill
        // walks the Sent folder. Skip the inbox call entirely on the very first poll.
        if !accountSnapshot.backfillCompleted {
            await runBackfill(accountID: accountSnapshot.id)
        }

        let fromAddresses = await MainActor.run { self.threadStore.outboundRecipients() }
        do {
            let pollResult = try await client.listInbox(
                sinceUID: localSnapshot.inboxLastUID,
                expectedUIDValidity: localSnapshot.inboxUIDValidity,
                fromAddresses: fromAddresses
            )
            let messages = pollResult.messages
            let observedUIDValidity = pollResult.uidValidity
            let validityChanged = observedUIDValidity != 0 && observedUIDValidity != localSnapshot.inboxUIDValidity

            let accountID = self.accountID
            let inserted: [NotificationService.InboundReply] = await MainActor.run {
                var newOnes: [NotificationService.InboundReply] = []
                for msg in messages {
                    guard let stored = self.threadStore.recordInbound(message: msg, accountID: accountID) else { continue }
                    let issue: NotificationService.InboundReply.IssueRef? = {
                        guard let t = stored.thread, t.issueNumber > 0,
                              !t.issueRepoOwner.isEmpty, !t.issueRepoName.isEmpty else { return nil }
                        return .init(owner: t.issueRepoOwner, repo: t.issueRepoName, number: t.issueNumber)
                    }()
                    newOnes.append(.init(
                        messageID: stored.messageID,
                        fromName: stored.fromName,
                        fromAddress: stored.fromAddress,
                        subject: stored.subject,
                        issue: issue
                    ))
                }
                return newOnes
            }

            if let notificationService, !inserted.isEmpty {
                await notificationService.notifyInboundReplies(inserted)
            }

            // After a UIDVALIDITY reset, listInbox already searched from UID 0 — so
            // `messages.map(\.uid).max()` is the new high-water mark. Otherwise the previous
            // value carries forward when no messages were returned.
            let baselineUID: UInt32 = validityChanged ? 0 : localSnapshot.inboxLastUID
            let maxUID = messages.map(\.uid).max() ?? baselineUID
            let now = clock()

            await MainActor.run {
                self.localState.update(accountID: accountID) { ls in
                    if validityChanged {
                        // Hard-reset both fields together — `inboxLastUID` from the old UID
                        // space is meaningless against the new one.
                        ls.inboxLastUID = maxUID
                        ls.inboxUIDValidity = observedUIDValidity
                    } else {
                        if maxUID > ls.inboxLastUID {
                            ls.inboxLastUID = maxUID
                        }
                        if observedUIDValidity != 0 && ls.inboxUIDValidity != observedUIDValidity {
                            // First successful poll after install (or after the shared-state
                            // bug left validity at 0). Record it so future drift can be detected.
                            ls.inboxUIDValidity = observedUIDValidity
                        }
                    }
                    ls.lastSuccessfulPollAt = now
                    if ls.consecutiveFailures != 0 { ls.consecutiveFailures = 0 }
                }
            }

            if self.status != .idle { self.status = .idle }
            await MainActor.run {
                self.activityLog.finish(logID, status: .success, detail: "\(messages.count) message(s)")
            }

            // Detached so a slow GitHub round-trip doesn't gate the next poll cycle. The
            // mirror is idempotent (githubCommentID dedupes) so re-entering on the next
            // poll before this one finishes is safe.
            if let mirror {
                Task.detached { await mirror.mirrorPendingInbound() }
            }

            // Best-effort: pull attachments for replies WE sent from the Sent folder. Runs after a
            // healthy inbox poll, self-gates to nothing when no reply awaits enrichment, and is
            // fully isolated (its own error handling) so it can never disturb the inbox cadence.
            await runSentEnrichment()

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
                self.localState.update(accountID: accountID) { ls in
                    ls.consecutiveFailures += 1
                }
                self.activityLog.finish(logID, status: .failure, detail: errorMessage)
            }
        }
    }

    /// Pulls attachment structure for app-composed outbound replies from the Sent folder (matched by
    /// exact Message-Id) and upgrades the matching local rows (uid + folder + MailAttachment
    /// children). Best-effort and fully isolated: any failure (including a provider with no Sent
    /// folder) is logged and swallowed so the inbox poll's cadence, backoff, and auth-stop are never
    /// affected. Self-gates via `outboundNeedingEnrichment`, so once replies are enriched the steady
    /// state skips the Sent folder entirely (zero IMAP work). There is no UID watermark: a reply not
    /// yet found is simply retried next pass until it is found or ages out of the gate window.
    private func runSentEnrichment() async {
        let accountID = self.accountID
        let since = clock().addingTimeInterval(-Self.sentEnrichmentWindow)
        let gateIDs = await MainActor.run { self.threadStore.outboundNeedingEnrichment(since: since, accountID: accountID) }
        // Forget attempt counts for replies no longer pending (enriched, deleted, or aged out).
        enrichmentAttempts = enrichmentAttempts.filter { gateIDs.contains($0.key) }
        // Drop replies we've already tried too many times this session — their Sent copy isn't
        // turning up, so stop forcing a Sent scan every poll for them.
        let enrichIDs = gateIDs.filter { (enrichmentAttempts[$0] ?? 0) < Self.maxEnrichmentAttempts }
        guard !enrichIDs.isEmpty else { return }

        do {
            let messages = try await client.listSentForEnrichment(sinceDate: since, messageIDs: enrichIDs)
            let enrichedIDs = Set(messages.map(\.messageID))
            // Clear the counter for found replies; count a miss for the rest so a perpetually-
            // unfindable reply eventually drops out (above) instead of scanning forever.
            for id in enrichIDs {
                if enrichedIDs.contains(id) { enrichmentAttempts[id] = nil }
                else { enrichmentAttempts[id, default: 0] += 1 }
            }
            // Nothing found this pass → no store write and no activity-log entry (avoids per-poll
            // "0 enriched" log noise while a reply's Sent copy hasn't been filed yet).
            guard !messages.isEmpty else { return }
            await MainActor.run {
                let logID = self.activityLog.start(kind: .fetchMail, title: "Sync sent attachments")
                self.threadStore.withBatch {
                    for m in messages {
                        self.threadStore.upgradeOutbound(
                            messageID: m.messageID,
                            uid: m.uid,
                            folder: m.folder,
                            uidValidity: m.uidValidity,
                            attachments: m.attachments,
                            accountID: accountID
                        )
                    }
                }
                self.activityLog.finish(logID, status: .success, detail: "\(messages.count) enriched")
            }
        } catch {
            // Count a failed attempt for every requested id so a persistently-failing pass (e.g. no
            // Sent folder) stops scanning after maxEnrichmentAttempts. Swallow: Sent enrichment must
            // never disturb the proven inbox poll cadence/backoff/auth-stop.
            for id in enrichIDs { enrichmentAttempts[id, default: 0] += 1 }
            print("[MailSyncCoordinator] sent enrichment failed (non-fatal): \(error)")
        }
    }

    /// Performs the one-time backfill of the Sent folder.
    private func runBackfill(accountID: UUID) async {
        // Cap backfill attempts to avoid endless retries on persistent failures.
        let maxBackfillFailures = 3
        let currentFailureCount = await MainActor.run {
            self.localState.state(accountID: accountID)?.backfillFailureCount ?? 0
        }
        if currentFailureCount >= maxBackfillFailures {
            // Already exceeded cap — skip silently (backfillCompleted was flipped on the third failure).
            return
        }

        // Backfill exists to seed outbound recipients (so the inbox poll's FROM filter
        // knows who to look for) and to thread historical Sent messages. A 365-day window
        // routinely overruns SwiftMail's per-command timeout on real Gmail accounts —
        // structure fetches are sequential and a year of Sent is hundreds-to-thousands of
        // messages. 14 days is enough to capture recent feedback exchanges; older replies
        // surface naturally as the user resumes activity.
        let cutoff = clock().addingTimeInterval(-14 * 24 * 3600)
        let accountLabel = await MainActor.run { accountStore.account(id: accountID)?.smtpUsername ?? "—" }
        let backfillLogID = await MainActor.run {
            self.activityLog.start(kind: .fetchMail, title: "Backfill sent folder (\(accountLabel))")
        }

        do {
            let sentMessages = try await client.listSent(sinceDate: cutoff)
            let knownTitles = await knownIssueTitlesProvider()

            await MainActor.run {
                self.threadStore.withBatch {
                    for msg in sentMessages {
                        // Prefer the issue identity encoded in the Message-Id we generated at
                        // send time — survives custom subjects, repo renames, and stale issue
                        // title caches. Fall back to subject substring matching for messages
                        // sent before this scheme existed (or via clients other than this app).
                        let idMatch = MessageIDGenerator.parseIssueContext(from: msg.messageID)
                        let subjectMatch = idMatch == nil
                            ? ThreadMatcher.matchToIssue(threadSubject: msg.subject, knownIssueTitles: knownTitles)
                            : nil
                        let match = idMatch ?? subjectMatch
                        // Record every outbound, including orphans. Even if a message can't be
                        // tied to a GitHub issue, we still want its recipient address in the
                        // store so the next inbox poll's `FROM` filter knows to look for replies.
                        // Orphans use issueNumber=0; recordOutbound creates an unattached thread.
                        self.threadStore.recordOutbound(
                            messageID: msg.messageID,
                            repoOwner: match?.owner ?? "",
                            repoName: match?.repo ?? "",
                            issueNumber: match?.number ?? 0,
                            from: msg.fromAddress,
                            fromName: msg.fromName,
                            to: msg.toAddresses,
                            cc: msg.ccAddresses,
                            subject: msg.subject,
                            bodyPlain: msg.bodyPlain,
                            bodyHTML: msg.bodyHTML,
                            date: msg.date,
                            accountID: accountID,
                            replyHeaders: nil
                        )
                    }
                }

                // Flip backfillCompleted and reset failure counter on success.
                self.accountStore.update(id: accountID) { acc in
                    acc.backfillCompleted = true
                }
                self.localState.update(accountID: accountID) { ls in
                    if ls.backfillFailureCount != 0 { ls.backfillFailureCount = 0 }
                }
                self.activityLog.finish(
                    backfillLogID,
                    status: .success,
                    detail: "\(sentMessages.count) sent message(s) backfilled"
                )
            }

        } catch {
            let errorMessage = error.localizedDescription
            await MainActor.run {
                // Increment failure count; after max failures, flip backfillCompleted
                // so the polling loop stops retrying indefinitely.
                let newCount = (self.localState.state(accountID: accountID)?.backfillFailureCount ?? 0) + 1
                self.localState.update(accountID: accountID) { ls in ls.backfillFailureCount = newCount }

                let hitCap = newCount >= maxBackfillFailures
                if hitCap {
                    // Cap reached — mark backfill done so we don't retry forever.
                    self.accountStore.update(id: accountID) { acc in acc.backfillCompleted = true }
                    self.activityLog.finish(
                        backfillLogID,
                        status: .failure,
                        detail: "Backfill skipped after repeated failures: \(errorMessage)"
                    )
                } else {
                    // Below cap — leave backfillCompleted false so next poll will retry.
                    self.activityLog.finish(backfillLogID, status: .failure, detail: errorMessage)
                }
            }
        }
    }
}
