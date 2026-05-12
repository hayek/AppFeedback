import Foundation
import Observation

// MARK: - MailSyncCoordinatorHolder

/// Observable wrapper so SwiftUI can inject MailSyncCoordinator via @Environment.
/// Actors don't conform to Observable, so we wrap the reference here.
/// Task 12 will replace the nil placeholder with a real coordinator once IMAPClient is wired.
@Observable
final class MailSyncCoordinatorHolder {
    let coordinator: MailSyncCoordinator?
    init(_ coordinator: MailSyncCoordinator?) { self.coordinator = coordinator }
}

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
    private let accountID: UUID
    private let threadStore: MailThreadStore           // @MainActor
    private let accountStore: MailAccountStore         // @MainActor
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

    // MARK: - Init

    init(
        client: IMAPClientProtocol,
        accountID: UUID,
        threadStore: MailThreadStore,
        accountStore: MailAccountStore,
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
        self.localState = localState
        self.activityLog = activityLog
        self.mirror = mirror
        self.notificationService = notificationService
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
                let accountID = self.accountID
                let snapshot = await MainActor.run { () -> (intervalSeconds: Int, pollingEnabled: Bool, consecutiveFailures: Int) in
                    let account = self.accountStore.account(id: accountID)
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

        let accountID = self.accountID
        let accountSnapshot = await MainActor.run { () -> AccountSnapshot? in
            guard let acc = self.accountStore.account(id: accountID) else { return nil }
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

        let localSnapshot = await MainActor.run { () -> LocalStateSnapshot in
            let ls = self.localState.ensure(accountID: accountSnapshot.id)
            return LocalStateSnapshot(
                inboxLastUID: ls.inboxLastUID,
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
            let messages = try await client.listInbox(
                sinceUID: localSnapshot.inboxLastUID,
                fromAddresses: fromAddresses
            )

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

            let maxUID = messages.map(\.uid).max() ?? localSnapshot.inboxLastUID
            let now = clock()

            await MainActor.run {
                self.localState.update { ls in
                    if maxUID > ls.inboxLastUID {
                        ls.inboxLastUID = maxUID
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
        // Cap backfill attempts to avoid endless retries on persistent failures.
        let maxBackfillFailures = 3
        let currentFailureCount = await MainActor.run {
            self.localState.state?.backfillFailureCount ?? 0
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
                self.localState.update { ls in
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
                let newCount = (self.localState.state?.backfillFailureCount ?? 0) + 1
                self.localState.update { ls in ls.backfillFailureCount = newCount }

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
