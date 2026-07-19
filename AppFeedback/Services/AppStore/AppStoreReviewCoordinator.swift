import Foundation

/// Polls one product's App Store reviews and synthesizes GitHub issues. Two modes:
///   • `poll()` (incremental) — walks `links.next` from the top of `-createdDate`, stopping at the
///     first review older than the last poll OR already in the mirror, synthesizing only the new
///     ones.
///   • `fullRescan()` (periodic) — walks ALL pages; catches edits (contentHash changed → update the
///     issue + "Review edited" note) and deletions (in the mirror but absent from the scan → close
///     the issue + `review-deleted` label + comment). Never hard-deletes.
/// Cross-device dedup is via the synced `AppStoreReviewMirror`. Failures throw to the caller (the
/// registry's poll loop owns backoff); the registry/loop never let one source block another.
actor AppStoreReviewCoordinator: FeedbackSourceIngestor {
    private let config: ASCProductConfig
    private let client: AppStoreConnectClientProtocol
    private let issueWriter: IssueWriting
    private let commentPoster: GitHubCommentPoster
    private let mirrorStore: AppStoreReviewMirrorStore     // @MainActor
    private let tokenLoader: @Sendable () async -> String?
    private let activityLog: ActivityLog?                  // @MainActor
    private let clock: @Sendable () -> Date

    // [F] Per-source status surfaced in AppStoreSourceForm (read via `status()` / the registry).
    private(set) var lastSuccessAt: Date?
    private(set) var lastError: String?
    // [responderContext] Flipped true after a 403 on a response write (read-only ASC key). The
    // registry exposes this through `responderContext(productID:)` so Phase 4 can disable the panel.
    private(set) var isReadOnly = false

    /// The product id this coordinator serves (used by the registry to key its lookups).
    var productID: UUID { config.id }
    /// The injected client (handed to Phase 4 via the registry's responder context).
    var responderClient: any AppStoreConnectClientProtocol { client }
    var sinkOwner: String { config.owner }
    var sinkRepo: String { config.repo }

    /// Snapshot of the per-source status for the settings UI.
    func status() -> (lastSuccessAt: Date?, lastError: String?) { (lastSuccessAt, lastError) }
    func readOnly() -> Bool { isReadOnly }
    /// Phase 4 calls this after a 403 on a response write to disable the respond panel.
    func markReadOnly() { isReadOnly = true }

    private var lastIncrementalPollAt: Date?
    private var loopTask: Task<Void, Never>?
    private var inFlight = false
    private var consecutiveFailures = 0
    /// Run a full re-scan once every ~24h of wall-clock between successful incremental polls.
    private var lastFullRescanAt: Date?
    private static let fullRescanInterval: TimeInterval = 24 * 3600
    private static let maxPages = 200    // safety cap (200 reviews/page × 200 = 40k)

    init(config: ASCProductConfig,
         client: AppStoreConnectClientProtocol,
         issueWriter: IssueWriting,
         commentPoster: GitHubCommentPoster,
         mirrorStore: AppStoreReviewMirrorStore,
         tokenLoader: @escaping @Sendable () async -> String?,
         activityLog: ActivityLog? = nil,
         clock: @escaping @Sendable () -> Date = { Date() }) {
        self.config = config
        self.client = client
        self.issueWriter = issueWriter
        self.commentPoster = commentPoster
        self.mirrorStore = mirrorStore
        self.tokenLoader = tokenLoader
        self.activityLog = activityLog
        self.clock = clock
    }

    // MARK: - FeedbackSourceIngestor

    func poll() async throws { try await incrementalPoll() }

    // MARK: - Lifecycle (background driver / scenePhase drive pollNow())

    func pollNow() async {
        guard !inFlight else { return }
        do {
            if shouldFullRescan() { try await fullRescan() } else { try await incrementalPoll() }
            consecutiveFailures = 0
            lastSuccessAt = clock()      // [F] stamp success; preserve any prior lastError? No — clear it.
            lastError = nil
        } catch {
            consecutiveFailures += 1
            lastError = (error as? LocalizedError)?.errorDescription ?? String(describing: error)  // [F]
        }
    }

    func start() {
        loopTask?.cancel()
        loopTask = Task { [weak self] in
            guard let self else { return }
            await self.pollNow()
            while !Task.isCancelled {
                let sleep = await Self.backoffSeconds(baseSeconds: 900, consecutiveFailures: self.failureCount())
                try? await Task.sleep(nanoseconds: UInt64(sleep) * 1_000_000_000)
                guard !Task.isCancelled else { return }
                await self.pollNow()
            }
        }
    }

    func stop() { loopTask?.cancel(); loopTask = nil }

    private func failureCount() -> Int { consecutiveFailures }
    private func shouldFullRescan() -> Bool {
        guard let last = lastFullRescanAt else { return false }   // first poll is incremental
        return clock().timeIntervalSince(last) >= Self.fullRescanInterval
    }

    /// Same Double-clamped formula as `MailSyncCoordinator.backoffSeconds` — clamp in Double space
    /// before the Int conversion so a large failure count can't trap on an out-of-range Double.
    static func backoffSeconds(baseSeconds: Int, consecutiveFailures: Int) -> Int {
        guard consecutiveFailures > 0 else { return baseSeconds }
        let backoff = 30.0 * pow(2.0, Double(consecutiveFailures - 1))
        return Int(min(Double(baseSeconds), backoff))
    }

    // MARK: - Incremental

    private func incrementalPoll() async throws {
        inFlight = true
        defer { inFlight = false }
        let since = lastIncrementalPollAt
        let startedAt = clock()
        var cursor: String? = nil
        var pages = 0
        outer: while pages < Self.maxPages {
            let page = try await client.listReviews(appAppleID: config.appAppleID, page: cursor)
            pages += 1
            for review in page.reviews {
                // Stop conditions: older than last poll, OR already known & unchanged.
                if let since, review.createdDate < since {
                    break outer
                }
                let known = await mirrorSnapshot(reviewId: review.id)
                let hash = AppStoreReviewSynthesizer.contentHash(for: review)
                if let known {
                    if known.contentHash == hash { break outer }   // hit a known, unchanged review
                    try await applyEdit(review: review, issueNumber: known.issueNumber, hash: hash)
                } else {
                    try await synthesizeNew(review: review, hash: hash)
                }
            }
            guard let next = page.nextCursor else { break }
            cursor = next
        }
        lastIncrementalPollAt = startedAt
        if lastFullRescanAt == nil { lastFullRescanAt = startedAt }   // seed so re-scans cadence from first poll
    }

    // MARK: - Full re-scan (edits + deletions)

    func fullRescan() async throws {
        inFlight = true
        defer { inFlight = false }
        let startedAt = clock()
        var cursor: String? = nil
        var pages = 0
        var seenReviewIDs = Set<String>()
        while pages < Self.maxPages {
            let page = try await client.listReviews(appAppleID: config.appAppleID, page: cursor)
            pages += 1
            for review in page.reviews {
                seenReviewIDs.insert(review.id)
                let hash = AppStoreReviewSynthesizer.contentHash(for: review)
                let known = await mirrorSnapshot(reviewId: review.id)
                if let known {
                    if known.contentHash != hash { try await applyEdit(review: review, issueNumber: known.issueNumber, hash: hash) }
                } else {
                    try await synthesizeNew(review: review, hash: hash)
                }
            }
            guard let next = page.nextCursor else { break }
            cursor = next
        }
        // Deletions: mirror rows whose review wasn't seen this scan. Snapshot (reviewId, issueNumber)
        // off the MainActor model objects — the model itself is not Sendable across the hop.
        let mirrors = await MainActor.run {
            mirrorStore.allFor(productID: config.id).map { ($0.reviewId, $0.issueNumber) }
        }
        for (reviewId, issueNumber) in mirrors where !seenReviewIDs.contains(reviewId) {
            try await applyDeletion(issueNumber: issueNumber)
        }
        lastFullRescanAt = startedAt
        lastIncrementalPollAt = startedAt
    }

    // MARK: - Synthesis primitives

    /// Sendable snapshot of a mirror row's fields needed off the MainActor. `AppStoreReviewMirror`
    /// (a `PersistentModel`) is NOT Sendable, so we never return the model object across the actor
    /// hop — only this value type.
    private struct MirrorSnapshot: Sendable { let issueNumber: Int; let contentHash: String }

    private func mirrorSnapshot(reviewId: String) async -> MirrorSnapshot? {
        await MainActor.run {
            guard let row = mirrorStore.mirror(reviewId: reviewId) else { return nil }
            return MirrorSnapshot(issueNumber: row.issueNumber, contentHash: row.contentHash)
        }
    }

    private func synthesizeNew(review: ASCReview, hash: String) async throws {
        guard let token = await tokenLoader(), !token.isEmpty else {
            throw AppStoreConnectError.http(0)   // no GitHub token ⇒ can't synthesize; retried next poll
        }
        // Cross-device backstop: if a mirror row appeared mid-poll (other device synced), skip.
        if let raced = await mirrorSnapshot(reviewId: review.id) {
            if raced.contentHash != hash { try await applyEdit(review: review, issueNumber: raced.issueNumber, hash: hash) }
            return
        }
        let number = try await issueWriter.createIssue(
            owner: config.owner, repo: config.repo,
            title: AppStoreReviewSynthesizer.title(for: review),
            body: AppStoreReviewSynthesizer.body(for: review),
            labels: AppStoreReviewSynthesizer.labels(for: review),
            milestoneNumber: nil, token: token)
        await MainActor.run {
            _ = mirrorStore.upsert(reviewId: review.id, productID: config.id, issueNumber: number, contentHash: hash)
        }
        await reconcileDuplicates(reviewId: review.id, token: token)
    }

    private func applyEdit(review: ASCReview, issueNumber: Int, hash: String) async throws {
        guard let token = await tokenLoader(), !token.isEmpty else { throw AppStoreConnectError.http(0) }
        let newBody = AppStoreReviewSynthesizer.body(for: review)
            + "\n\n" + AppStoreReviewSynthesizer.editedNote(at: clock())
        try await issueWriter.updateIssue(
            owner: config.owner, repo: config.repo, number: issueNumber,
            title: AppStoreReviewSynthesizer.title(for: review), body: newBody,
            labels: AppStoreReviewSynthesizer.labels(for: review),
            milestoneNumber: nil, state: nil, token: token)
        await MainActor.run {
            _ = mirrorStore.upsert(reviewId: review.id, productID: config.id, issueNumber: issueNumber, contentHash: hash)
        }
    }

    private func applyDeletion(issueNumber: Int) async throws {
        guard let token = await tokenLoader(), !token.isEmpty else { throw AppStoreConnectError.http(0) }
        // [G] The rating badge MUST survive the deletion close. The body carries the authoritative
        // `rating: N` marker that `IssueLoader.resolveRating` reads, so we pass `body: nil` — the
        // body is NEVER rewritten and every Phase-1 marker (source/rating/reviewId/…) is preserved.
        // We mark the issue closed and add `source:app-store` + `review-deleted`. We do NOT union the
        // existing labels (no GitHub read here); the badge does not depend on the `rating:N` LABEL
        // because the marker is authoritative for `resolveRating`.
        try await issueWriter.updateIssue(
            owner: config.owner, repo: config.repo, number: issueNumber,
            title: nil, body: nil,
            labels: ["source:app-store", AppStoreReviewSynthesizer.reviewDeletedLabel],
            milestoneNumber: nil, state: "closed", token: token)
        _ = try? await commentPoster.postComment(
            owner: config.owner, repo: config.repo, issueNumber: issueNumber,
            body: "_This App Store review was deleted by its author._", token: token)
    }

    /// [D-reconcile] There is no GitHub search API in the app, so the synced `AppStoreReviewMirror`
    /// is the authority. Because the model carries NO unique constraint, two devices polling the same
    /// product can each create an issue + mirror row for the SAME review; after CloudKit sync these
    /// appear as duplicate rows (same `reviewId`, different `issueNumber`). We collapse them:
    ///   • group mirror rows by `reviewId`,
    ///   • KEEP the row with the LOWEST `issueNumber`,
    ///   • close each higher GitHub issue via the issue writer,
    ///   • delete each extra mirror row via `deleteByIssue(productID:issueNumber:)`.
    /// The kept row is NEVER deleted. Idempotent: a single surviving row is a no-op.
    private func reconcileDuplicates(reviewId: String, token: String) async {
        // Snapshot issue numbers off the MainActor model objects before doing async work —
        // `AppStoreReviewMirror` (a PersistentModel) is not Sendable, so we must not return the
        // model objects across the actor hop; extract the plain `Int`s inside the closure.
        let issueNumbers = await MainActor.run {
            mirrorStore.allFor(productID: config.id)
                .filter { $0.reviewId == reviewId }
                .map(\.issueNumber)
                .sorted()
        }
        guard issueNumbers.count > 1 else { return }
        guard let kept = issueNumbers.first else { return }
        let extras = issueNumbers.dropFirst()   // everything above the lowest
        for higher in extras {
            try? await issueWriter.updateIssue(
                owner: config.owner, repo: config.repo, number: higher,
                title: nil, body: nil, labels: nil, milestoneNumber: nil, state: "closed", token: token)
            await MainActor.run {
                // Delete ONLY the duplicate row; the kept (lowest) row is untouched.
                mirrorStore.deleteByIssue(productID: config.id, issueNumber: higher)
            }
        }
        _ = kept   // kept row intentionally left in place
    }

    // MARK: - Test seam

    /// Exposes `reconcileDuplicates` to tests without driving a whole poll. Loads the GitHub token
    /// via the same loader production uses.
    func reconcileDuplicatesForTest(reviewId: String) async {
        let token = await tokenLoader() ?? "tok"
        await reconcileDuplicates(reviewId: reviewId, token: token)
    }
}
