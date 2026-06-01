import Foundation
import SwiftData
import CoreData
import Observation

@MainActor
@Observable
final class MailThreadStore {
    private let context: ModelContext

    /// Increments after every successful write. SwiftUI observers use this to re-fetch.
    private(set) var version: Int = 0

    /// Inbound messageIDs that arrived during this app session and the user hasn't acknowledged yet.
    /// Mirrors `IssueListViewModel.sessionUnread` — populated when `recordInbound` inserts a new
    /// message, drained when the row is tapped. In-memory only; resets on app launch so an existing
    /// inbox isn't flagged as new on first display.
    private(set) var sessionUnreadMessageIDs: Set<String> = []

    private var remoteChangeTask: Task<Void, Never>?
    private var cloudKitImportTask: Task<Void, Never>?

    init(context: ModelContext) {
        self.context = context

        // CloudKit pulls a MailMessage written by another device into the persistent store,
        // but no local code path calls commitChange() — so without this `version` would
        // never tick and IssueCardView's onChange(threadStore.version) refresh wouldn't fire,
        // leaving replies sent on another device invisible until app relaunch.
        remoteChangeTask = Task { @MainActor [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .NSPersistentStoreRemoteChange) {
                self?.notifyRemoteChange()
            }
        }

        // Belt-and-suspenders alongside NSPersistentStoreRemoteChange: that notification can
        // be missed or arrive before imported rows are visible to fetches on a fresh install.
        cloudKitImportTask = Task { @MainActor [weak self] in
            for await _ in NotificationCenter.cloudKitImportSucceeded {
                self?.notifyRemoteChange()
            }
        }
    }

    isolated deinit {
        remoteChangeTask?.cancel()
        cloudKitImportTask?.cancel()
    }

    private func notifyRemoteChange() {
        cachedCandidates = nil
        invalidateOrphanCache()
        version &+= 1
    }

    func isUnread(_ message: MailMessage) -> Bool {
        message.direction == .inbound && sessionUnreadMessageIDs.contains(message.messageID)
    }

    /// True when the thread has any inbound message that hasn't been viewed this session.
    /// Used by `IssueCardView` to surface the "new" badge when a user replies via email.
    func hasUnreadInbound(thread: MailThread) -> Bool {
        guard !sessionUnreadMessageIDs.isEmpty else { return false }
        return (thread.messages ?? []).contains(where: isUnread)
    }

    func markSeen(_ messageID: String) {
        guard sessionUnreadMessageIDs.remove(messageID) != nil else { return }
        version &+= 1
    }

    /// Unique recipient addresses across all outbound messages. The mail sync uses these as
    /// the FROM filter when polling the inbox — replies come from people we've written to.
    func outboundRecipients() -> [String] {
        let outboundRaw = MailMessage.Direction.outbound.rawValue
        let descriptor = FetchDescriptor<MailMessage>(
            predicate: #Predicate { $0.directionRaw == outboundRaw }
        )
        let messages = (try? context.fetch(descriptor)) ?? []
        var seen = Set<String>()
        var result: [String] = []
        for m in messages {
            for addr in m.toAddresses where !addr.isEmpty && seen.insert(addr).inserted {
                result.append(addr)
            }
        }
        return result
    }

    /// Cascade-deletes every thread (which removes its messages and attachments) and
    /// bumps `version` so SwiftUI observers re-fetch.
    func deleteAll() {
        let descriptor = FetchDescriptor<MailThread>()
        let threads = (try? context.fetch(descriptor)) ?? []
        for t in threads { context.delete(t) }
        do {
            try context.save()
        } catch {
            assertionFailure("MailThreadStore deleteAll save failed: \(error)")
        }
        cachedCandidates = nil
        invalidateOrphanCache()
        version &+= 1
    }

    // MARK: - Per-poll candidate cache

    /// Cached result of `recentThreadsForFallback` so multiple `recordInbound` calls within
    /// a single poll cycle each re-use the same snapshot rather than issuing N fetches.
    /// Invalidated by every successful write so newly-created threads are immediately visible
    /// to subsequent subject-fallback resolution within the same poll batch.
    private var cachedCandidates: [MailThread]?
    private var candidatesCachedAt: Date = .distantPast

    /// One poll cycle is the design horizon — the cache exists to amortize per-message
    /// fetches inside a single batch, not to live across user-visible time windows.
    private static let candidateCacheTTL: TimeInterval = 1.0
    private static let candidateFallbackLimit: Int = 200

    private func recentThreadCandidatesCached() -> [MailThread] {
        let now = Date()
        if let cached = cachedCandidates,
           now.timeIntervalSince(candidatesCachedAt) < Self.candidateCacheTTL {
            return cached
        }
        let fresh = recentThreadsForFallback(limit: Self.candidateFallbackLimit)
        cachedCandidates = fresh
        candidatesCachedAt = now
        return fresh
    }

    // MARK: - Resolution enum

    private enum Resolution {
        case existingHeader(MailThread)
        case existingReferences(MailThread)
        case new(MailThread)
    }

    // MARK: - recordOutbound

    /// True while a `withBatch { ... }` is in progress. Suppresses per-call save/version-bump
    /// so callers can record many messages at once without thrashing CloudKit or SwiftUI.
    private var batchInProgress: Bool = false

    /// Set by `commitChange` while a batch is active, so a batch that mutated nothing (e.g. a
    /// Sent-enrichment poll whose replies aren't filed in Sent yet) skips the save/version-bump
    /// and doesn't force every observer to re-fetch.
    private var batchDirty: Bool = false

    /// Runs `body` with `recordOutbound`/`recordInbound` writes coalesced into a single
    /// save+version-bump at the end. Used by backfill to avoid hundreds of round-trips.
    /// The flush is skipped entirely when nothing inside requested a commit.
    func withBatch(_ body: () -> Void) {
        batchInProgress = true
        batchDirty = false
        defer { batchInProgress = false }
        body()
        guard batchDirty else { return }
        do {
            try context.save()
            version += 1
            cachedCandidates = nil
            invalidateOrphanCache()
        } catch {
            assertionFailure("MailThreadStore batch save failed: \(error)")
        }
    }

    /// Save + version bump + cache invalidation for a single-message write. No-op while a
    /// `withBatch { ... }` is active — the batch flushes everything at the end (and only if a
    /// commit was actually requested).
    private func commitChange(createdNewThread: Bool) {
        if batchInProgress {
            batchDirty = true
            if createdNewThread { cachedCandidates = nil; invalidateOrphanCache() }
            return
        }
        do {
            try context.save()
            version += 1
            if createdNewThread {
                cachedCandidates = nil
                invalidateOrphanCache()
            }
        } catch {
            assertionFailure("MailThreadStore save failed: \(error)")
        }
    }

    @discardableResult
    func recordOutbound(
        messageID: String,
        repoOwner: String, repoName: String, issueNumber: Int,
        from: String, fromName: String?,
        to: [String], cc: [String],
        subject: String, bodyPlain: String, bodyHTML: String?,
        date: Date,
        accountID: UUID? = nil,
        replyHeaders: ReplyHeaderBuilder.Output?
    ) -> MailMessage {
        // Dedupe: return existing message if messageID already stored
        if let existing = findMessage(byMessageID: messageID) {
            return existing
        }

        // Determine which thread to append to (header-based lookup)
        let resolution = resolveThread(
            inReplyTo: replyHeaders?.inReplyTo,
            references: replyHeaders?.references ?? [],
            fallback: {
                // Create new thread
                let newThread = MailThread(
                    messageIDRoot: messageID,
                    subject: subject,
                    lastMessageAt: date,
                    issueRepoOwner: issueNumber > 0 ? repoOwner : "",
                    issueRepoName: issueNumber > 0 ? repoName : "",
                    issueNumber: issueNumber > 0 ? issueNumber : 0,
                    matchSourceRaw: MailThread.MatchSource.direct.rawValue
                )
                self.context.insert(newThread)
                newThread.accountID = accountID
                return newThread
            }
        )

        let thread: MailThread
        let createdNewThread: Bool
        switch resolution {
        case .existingHeader(let t):
            // Matched via inReplyTo — leave matchSource as previously set
            thread = t
            createdNewThread = false
        case .existingReferences(let t):
            // Matched via references chain — upgrade matchSource to .header if currently .direct
            if t.matchSource == .direct {
                t.matchSource = .header
            }
            thread = t
            createdNewThread = false
        case .new(let t):
            // New thread created in fallback — matchSource already set to .direct
            thread = t
            createdNewThread = true
        }

        if thread.accountID == nil { thread.accountID = accountID }

        // Update thread metadata
        thread.lastMessageAt = max(thread.lastMessageAt, date)
        let newParticipants = ([from] + to + cc).filter { !$0.isEmpty }
        thread.participants = unionPreservingOrder(thread.participants, newParticipants)

        // Build the new message
        let msg = MailMessage(
            messageID: messageID,
            inReplyTo: replyHeaders?.inReplyTo,
            references: replyHeaders?.references.joined(separator: "\n") ?? "",
            fromAddress: from,
            fromName: fromName,
            toAddresses: to,
            ccAddresses: cc,
            date: date,
            subject: subject,
            bodyPlain: bodyPlain,
            bodyHTML: bodyHTML,
            directionRaw: MailMessage.Direction.outbound.rawValue,
            thread: thread
        )
        context.insert(msg)
        msg.accountID = accountID

        commitChange(createdNewThread: createdNewThread)
        return msg
    }

    // MARK: - recordInbound

    @discardableResult
    func recordInbound(message: ParsedInboundMessage, accountID: UUID? = nil) -> MailMessage? {
        // Dedupe: skip if messageID already exists
        if findMessage(byMessageID: message.messageID) != nil {
            return nil
        }

        // Determine thread via direct header lookup first, then subject fallback via ThreadMatcher.
        var headerResolution: Resolution? = nil
        let resolution = resolveThread(
            inReplyTo: message.inReplyTo,
            references: message.references,
            fallback: {
                // Header-based lookup found nothing — attempt subject fallback using ThreadMatcher.
                // Only try fallback when the message looks like a reply (Re:/Fwd: prefix).
                let looksLikeReply = ThreadMatcher.stripReplyPrefixes(message.subject) != message.subject

                if looksLikeReply {
                    let recentThreads = self.recentThreadCandidatesCached()
                    let candidates: [ThreadMatcher.Candidate] = recentThreads.map { thread in
                        ThreadMatcher.Candidate(
                            messageID: thread.messageIDRoot,
                            subject: thread.subject,
                            participants: thread.participants,
                            lastMessageAt: thread.lastMessageAt
                        )
                    }
                    let result = ThreadMatcher.attach(message: message, existing: candidates)
                    switch result {
                    case .subject(let i):
                        let matched = recentThreads[i]
                        matched.matchSource = .subjectFallback
                        matched.accountID = matched.accountID ?? accountID
                        headerResolution = .existingHeader(matched)
                        return matched
                    case .header, .newThread:
                        // .header here would mean ThreadMatcher found a header match against
                        // candidates' messageIDRoot — but our prior resolveThread already covered
                        // direct header lookup against every stored MailMessage.messageID.
                        // Treat both as no-match and fall through to creating an orphan thread.
                        break
                    }
                }

                // Create orphan thread — issueNumber = 0, matchSource = .direct (placeholder)
                let newThread = MailThread(
                    messageIDRoot: message.messageID,
                    subject: message.subject,
                    lastMessageAt: message.date,
                    issueRepoOwner: "",
                    issueRepoName: "",
                    issueNumber: 0,
                    matchSourceRaw: MailThread.MatchSource.direct.rawValue
                )
                self.context.insert(newThread)
                newThread.accountID = accountID
                return newThread
            }
        )

        // If ThreadMatcher already set the resolution inside the fallback, use it directly.
        let finalResolution = headerResolution ?? resolution

        let thread: MailThread
        let createdNewThread: Bool
        switch finalResolution {
        case .existingHeader(let t):
            // Matched via inReplyTo or subject fallback — matchSource already set above.
            thread = t
            createdNewThread = false
        case .existingReferences(let t):
            // Matched via references chain — set matchSource to .header
            t.matchSource = .header
            thread = t
            createdNewThread = false
        case .new(let t):
            // New orphan thread — matchSource already .direct (placeholder)
            thread = t
            createdNewThread = true
        }

        if thread.accountID == nil { thread.accountID = accountID }

        // Update thread metadata
        thread.lastMessageAt = max(thread.lastMessageAt, message.date)
        let newParticipants = ([message.fromAddress] + message.toAddresses + message.ccAddresses)
            .filter { !$0.isEmpty }
        thread.participants = unionPreservingOrder(thread.participants, newParticipants)

        // Build message
        let msg = MailMessage(
            messageID: message.messageID,
            inReplyTo: message.inReplyTo,
            references: message.references.joined(separator: "\n"),
            fromAddress: message.fromAddress,
            fromName: message.fromName,
            toAddresses: message.toAddresses,
            ccAddresses: message.ccAddresses,
            date: message.date,
            subject: message.subject,
            bodyPlain: message.bodyPlain,
            bodyHTML: message.bodyHTML,
            directionRaw: MailMessage.Direction.inbound.rawValue,
            uid: Int(message.uid),
            folder: message.folder,
            uidValidity: Int(message.uidValidity),
            thread: thread
        )
        context.insert(msg)
        msg.accountID = accountID

        // Create MailAttachment rows for each parsed attachment
        for meta in message.attachments {
            let attachment = MailAttachment(
                messageID: message.messageID,
                partID: meta.partID,
                filename: meta.filename,
                mimeType: meta.mimeType,
                sizeBytes: meta.sizeBytes,
                contentID: meta.contentID,
                message: msg
            )
            context.insert(attachment)
        }

        sessionUnreadMessageIDs.insert(message.messageID)
        commitChange(createdNewThread: createdNewThread)
        return msg
    }

    // MARK: - Sent enrichment

    /// Records that an outbound message was successfully sent: stamps `sentAt` and persists it
    /// immediately (with a `version` bump) so the "Sent" badge survives relaunch/CloudKit and the
    /// enrichment gate — which requires `sentAt != nil` — sees it even if the app terminates before
    /// the next write. Stamps every outbound row with this Message-Id (CloudKit duplicates) and is
    /// idempotent: a row already stamped is left untouched, so a resend doesn't move the timestamp.
    func markSent(messageID: String, at date: Date = Date()) {
        let outboundRaw = MailMessage.Direction.outbound.rawValue
        let matches = (try? context.fetch(FetchDescriptor<MailMessage>(
            predicate: #Predicate { $0.messageID == messageID && $0.directionRaw == outboundRaw }
        ))) ?? []
        var changed = false
        for msg in matches where msg.sentAt == nil {
            msg.sentAt = date
            changed = true
        }
        if changed { commitChange(createdNewThread: false) }
    }

    /// Stamps locally-recorded outbound message(s) with the IMAP identity (uid + Sent folder) and
    /// attachment rows discovered in the Sent folder, matched by Message-Id. This is how attachments
    /// on replies WE composed become visible: the bytes live on the server, and once the message has
    /// a real uid/folder + MailAttachment rows the existing downloader fetches them like inbound.
    ///
    /// Stamps EVERY outbound row with this Message-Id, not just one: CloudKit can leave duplicate
    /// rows for the same message (no unique constraint on relationship-bearing models), and the
    /// deduped thread view may display a different duplicate than an arbitrary single-row lookup
    /// would stamp — so the attachments must land on all of them.
    ///
    /// Idempotent: never downgrades an already-stamped uid/folder, inserts only attachment rows
    /// whose `partID` isn't already present, and routes through `commitChange` (a no-op on a
    /// no-change re-poll, so no spurious save/version-bump/CloudKit push). Returns whether anything
    /// changed. Unlike `recordOutbound`, it does NOT early-return on a known Message-Id — upgrading
    /// the existing row is the whole point.
    @discardableResult
    func upgradeOutbound(
        messageID: String,
        uid: UInt32,
        folder: String,
        uidValidity: UInt32 = 0,
        attachments: [ParsedAttachmentMeta],
        accountID: UUID?
    ) -> Bool {
        let outboundRaw = MailMessage.Direction.outbound.rawValue
        let matches = (try? context.fetch(FetchDescriptor<MailMessage>(
            predicate: #Predicate { $0.messageID == messageID && $0.directionRaw == outboundRaw }
        ))) ?? []
        guard !matches.isEmpty else { return false }

        var changed = false
        for msg in matches {
            if msg.uid == 0 && uid > 0 { msg.uid = Int(uid); changed = true }
            if msg.folder.isEmpty && !folder.isEmpty { msg.folder = folder; changed = true }
            // Stamp uidValidity alongside uid so the download path can detect a stale uid after a
            // Sent-folder UIDVALIDITY reset (set together; both come from the same SELECT).
            if msg.uidValidity == 0 && uidValidity > 0 { msg.uidValidity = Int(uidValidity); changed = true }
            if msg.accountID == nil, let accountID { msg.accountID = accountID; changed = true }

            let existingPartIDs = Set((msg.attachments ?? []).map(\.partID))
            for meta in attachments where !existingPartIDs.contains(meta.partID) {
                let isImage = meta.mimeType.lowercased().hasPrefix("image/")
                let attachment = MailAttachment(
                    messageID: msg.messageID,
                    partID: meta.partID,
                    filename: meta.filename,
                    mimeType: meta.mimeType,
                    sizeBytes: meta.sizeBytes,
                    // A composed image's Sent copy carries no Content-ID, so synthesize one to route
                    // it into the inline-thumbnail row (local display only — does not touch the sent
                    // mail). Non-images stay nil and render as chips.
                    contentID: meta.contentID ?? (isImage ? "<local-\(meta.partID)@appfeedback>" : nil),
                    message: msg
                )
                context.insert(attachment)
                changed = true
            }
        }

        if changed { commitChange(createdNewThread: false) }
        return changed
    }

    /// Message-Ids of outbound messages still awaiting Sent-folder enrichment, used as the gate that
    /// bounds (and usually skips) the Sent scan. A row qualifies when it is app-composed (carries our
    /// outbound domain), successfully sent (`sentAt != nil` — a failed send has no Sent copy to find),
    /// not yet stamped (`uid == 0` is the sole "done" signal, so a reply with no attachments enriches
    /// once and drops out), and recent (`date >= since` — a reply that never enriched within the
    /// window must stop forcing a Sent scan forever). When empty the coordinator does zero IMAP work.
    func outboundNeedingEnrichment(since: Date, accountID: UUID, limit: Int = 50) -> Set<String> {
        let outboundRaw = MailMessage.Direction.outbound.rawValue
        let domain = MessageIDGenerator.outboundDomain
        // Scoped to THIS account (`accountID`): each per-account coordinator must only search its own
        // Sent folder, or it would burn a login+search every poll chasing another account's replies
        // it can never find. `fetchLimit` bounds the main-thread materialization.
        var descriptor = FetchDescriptor<MailMessage>(
            predicate: #Predicate {
                $0.directionRaw == outboundRaw && $0.uid == 0 && $0.sentAt != nil
                    && $0.date >= since && $0.accountID == accountID
                    && $0.messageID.contains(domain)
            },
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        let messages = (try? context.fetch(descriptor)) ?? []
        return Set(messages.map(\.messageID))
    }

    // MARK: - threads(forIssue:)

    func threads(forIssue issue: (owner: String, repo: String, number: Int, title: String)) -> [MailThread] {
        let owner = issue.owner
        let repo = issue.repo
        let number = issue.number
        let attached = FetchDescriptor<MailThread>(
            predicate: #Predicate {
                $0.issueRepoOwner == owner &&
                $0.issueRepoName == repo &&
                $0.issueNumber == number
            },
            sortBy: [SortDescriptor(\.lastMessageAt, order: .reverse)]
        )
        var results = (try? context.fetch(attached)) ?? []

        // Backfill couldn't always tie a Sent message to a GitHub issue (CachedIssue may
        // have been empty at the time, or the issue list was stale). Surface orphan threads
        // whose subject substring-matches this issue's title so replies don't get stranded.
        for orphan in cachedOrphans()
            where ThreadMatcher.subjectMatchesIssueTitle(subject: orphan.subject, issueTitle: issue.title) {
            results.append(orphan)
        }
        results.sort { $0.lastMessageAt > $1.lastMessageAt }
        return results
    }

    /// Orphan threads (`issueNumber == 0`) cached and invalidated only when the orphan set
    /// could have changed (new thread inserted, deleteAll). `threads(forIssue:)` is hit on
    /// every IssueCardView render, so without this cache each card fetches every orphan
    /// from SwiftData and re-runs subject normalization. Decoupled from `version` so
    /// unread-state mutations (markSeen) don't force a re-fetch.
    private var cachedOrphansList: [MailThread]?
    private func cachedOrphans() -> [MailThread] {
        if let cached = cachedOrphansList { return cached }
        let descriptor = FetchDescriptor<MailThread>(predicate: #Predicate { $0.issueNumber == 0 })
        let fresh = (try? context.fetch(descriptor)) ?? []
        cachedOrphansList = fresh
        return fresh
    }
    private func invalidateOrphanCache() { cachedOrphansList = nil }

    // MARK: - Private helpers

    /// Returns up to `limit` threads sorted by lastMessageAt descending, used for subject fallback.
    private func recentThreadsForFallback(limit: Int) -> [MailThread] {
        var descriptor = FetchDescriptor<MailThread>(
            sortBy: [SortDescriptor(\.lastMessageAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return (try? context.fetch(descriptor)) ?? []
    }

    private func findMessage(byMessageID messageID: String) -> MailMessage? {
        var descriptor = FetchDescriptor<MailMessage>(
            predicate: #Predicate { $0.messageID == messageID }
        )
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    /// Resolve a thread from inReplyTo / references headers, or call `fallback` to create a new one.
    private func resolveThread(
        inReplyTo: String?,
        references: [String],
        fallback: () -> MailThread
    ) -> Resolution {
        // 1. Check inReplyTo against any stored MailMessage.messageID
        if let inReplyTo, !inReplyTo.isEmpty,
           let parent = findMessage(byMessageID: inReplyTo),
           let parentThread = parent.thread {
            return .existingHeader(parentThread)
        }

        // 2. Walk references chain — one bulk fetch for all reference IDs, then pick
        //    the thread of the newest matching message.
        if !references.isEmpty {
            let descriptor = FetchDescriptor<MailMessage>(
                predicate: #Predicate { references.contains($0.messageID) }
            )
            let candidates = (try? context.fetch(descriptor)) ?? []
            if let newest = candidates.max(by: { $0.date < $1.date }),
               let thread = newest.thread {
                return .existingReferences(thread)
            }
        }

        // 3. No match — invoke fallback to create a new thread
        return .new(fallback())
    }

    /// Stamps every existing thread and message with the given accountID **only when it is
    /// currently nil**. Used by the v2 multi-account migration to retroactively associate
    /// pre-migration rows with the user's sole account. Cheap on re-run: the predicate
    /// short-circuits when nothing is nil.
    func backfillAccountIDIfMissing(_ accountID: UUID) {
        let threadDescriptor = FetchDescriptor<MailThread>(
            predicate: #Predicate { $0.accountID == nil }
        )
        let threads = (try? context.fetch(threadDescriptor)) ?? []
        for t in threads { t.accountID = accountID }

        let messageDescriptor = FetchDescriptor<MailMessage>(
            predicate: #Predicate { $0.accountID == nil }
        )
        let messages = (try? context.fetch(messageDescriptor)) ?? []
        for m in messages { m.accountID = accountID }

        if !threads.isEmpty || !messages.isEmpty {
            try? context.save()
        }
    }

    /// Merge `additions` into `base`, preserving insertion order and skipping duplicates.
    private func unionPreservingOrder(_ base: [String], _ additions: [String]) -> [String] {
        var seen = Set(base)
        var result = base
        for item in additions {
            if seen.insert(item).inserted {
                result.append(item)
            }
        }
        return result
    }
}
