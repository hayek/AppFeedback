import Foundation
import Observation
import SwiftData

@Observable @MainActor
final class IssueListViewModel {
    var allIssues: [FeedbackIssue] = []
    /// App names that are hidden for the current repo. Issues whose `appName`
    /// is in this set are excluded from all derived properties and counts.
    var hiddenApps: Set<String> = []

    /// Rolling window for AI summary (respects hidden apps + current app scope like `visibleBase`).
    private static let summarizationWindowDays = 30
    /// When at least this many issues are unread, AI summarizes unread only instead of the rolling-month digest.
    private static let minUnreadIssuesToPreferUnreadSummary = 2

    var unreadIssues: [FeedbackIssue] {
        allIssues.filter { sessionUnread.contains($0.number) && !hiddenApps.contains($0.appName ?? "") }
    }

    /// `true` when the summary card should summarize the unread backlog; otherwise rolling 30 days.
    var aiSummarizesUnreadIssuesOnly: Bool {
        unreadIssues.count >= Self.minUnreadIssuesToPreferUnreadSummary
    }

    /// Issues sent to Apple Intelligence — unread batch when catching up has enough novelty, otherwise the rolling window digest.
    var issuesForAISummaryCard: [FeedbackIssue] {
        if aiSummarizesUnreadIssuesOnly {
            unreadIssues.sorted { $0.createdAt > $1.createdAt }
        } else {
            issuesRecentForSummary
        }
    }

    /// Newest-first issues filed within roughly the past 30 days, for Apple Intelligence rollup.
    var issuesRecentForSummary: [FeedbackIssue] {
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -Self.summarizationWindowDays, to: Date())
        else { return [] }
        return visibleBase.filter { $0.createdAt >= cutoff }
            .sorted { $0.createdAt > $1.createdAt }
    }
    var searchQuery = ""
    var appFilter: Set<String> = []
    var allowsAppFilter: Bool = false
    var filters = ActiveFilters()
    /// Set by deep-link notification tap to highlight a specific issue.
    var highlightedIssueNumber: Int? = nil

    var uniqueAppNames: [String] {
        Array(Set(allIssues.compactMap(\.appName).filter { !hiddenApps.contains($0) })).sorted()
    }

    struct ActiveFilters: Equatable {
        var appVersion: Set<String> = []
        var device: Set<String> = []
        var osVersion: Set<String> = []
        var issueType: Set<IssueType> = []

        var isEmpty: Bool { appVersion.isEmpty && device.isEmpty && osVersion.isEmpty && issueType.isEmpty }
    }

    var visibleIssues: [FeedbackIssue] {
        var list = allIssues

        // Defensively hide any issue whose app is in the hidden set — this covers
        // the .allIssues (cross-app) view and the edge case of a hidden single app.
        if !hiddenApps.isEmpty {
            list = list.filter { !hiddenApps.contains($0.appName ?? "") }
        }

        if !appFilter.isEmpty {
            list = list.filter { appFilter.contains($0.appName ?? "") }
        }
        if !filters.appVersion.isEmpty { list = list.filter { filters.appVersion.contains($0.appVersion ?? "") } }
        if !filters.device.isEmpty     { list = list.filter { filters.device.contains($0.device ?? "") } }
        if !filters.osVersion.isEmpty  { list = list.filter { filters.osVersion.contains($0.osVersion ?? "") } }
        if !filters.issueType.isEmpty  { list = list.filter { ($0.labels.issueType?.type).map { filters.issueType.contains($0) } ?? false } }

        if !searchQuery.isEmpty {
            let q = searchQuery.lowercased()
            list = list.filter {
                $0.title.lowercased().contains(q) ||
                $0.description.lowercased().contains(q) ||
                ($0.appName ?? "").lowercased().contains(q) ||
                ($0.email ?? "").lowercased().contains(q)
            }
        }

        return list.sorted { $0.createdAt > $1.createdAt }
    }

    var uniqueIssueTypes: [IssueType] {
        let base = visibleBase
        let types = base.compactMap { $0.labels.issueType?.type }
        return Array(Set(types)).sorted { $0.displayName < $1.displayName }
    }

    func uniqueValues(for keyPath: KeyPath<FeedbackIssue, String?>) -> [String] {
        let base = visibleBase
        return Array(Set(base.compactMap { $0[keyPath: keyPath] })).sorted()
    }

    /// Distinct app versions present among the visible issues, sorted newest-first using a numeric
    /// (not lexicographic) comparison so "2.8" sorts above "2.6 (80)" above "1.6" above "0.1.0".
    var uniqueVersions: [String] {
        Array(Set(visibleBase.compactMap(\.appVersion)))
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
    }

    /// All issues with hidden apps filtered out, optionally narrowed to the selected app.
    private var visibleBase: [FeedbackIssue] {
        let withoutHidden = hiddenApps.isEmpty ? allIssues : allIssues.filter { !hiddenApps.contains($0.appName ?? "") }
        return appFilter.isEmpty ? withoutHidden : withoutHidden.filter { appFilter.contains($0.appName ?? "") }
    }

    func clearFilters() {
        filters = ActiveFilters()
    }

    /// Feedback-list filter selections for persistence (structured chips only — not `searchQuery`).
    var persistedFeedbackFilters: PersistedFeedbackFilters {
        PersistedFeedbackFilters(appVersion: filters.appVersion, device: filters.device,
                                 osVersion: filters.osVersion, issueType: filters.issueType,
                                 appFilter: appFilter)
    }

    func applyFeedbackFilters(_ dto: PersistedFeedbackFilters) {
        filters.appVersion = dto.appVersion
        filters.device = dto.device
        filters.osVersion = dto.osVersion
        filters.issueType = dto.issueType
        appFilter = dto.appFilter
    }

    private(set) var tasks: [TaskItem] = []

    private var seenStore: SeenIssueStore?
    private var seenOwner: String = ""
    private var seenRepo: String = ""
    private var sessionUnread: Set<Int> = []
    private var previouslyLoadedNumbers: Set<Int> = []

    func attachSeenStore(_ store: SeenIssueStore, owner: String, repo: String) {
        if seenOwner != owner || seenRepo != repo {
            sessionUnread = []
            previouslyLoadedNumbers = []
        }
        self.seenStore = store
        self.seenOwner = owner
        self.seenRepo = repo
    }

    func applyLoaded(_ issues: [FeedbackIssue]) {
        let taskIssues = issues.filter(TaskItem.isTask)
        let feedbackIssues = issues.filter { !TaskItem.isTask($0) }
        tasks = taskIssues.map(TaskItem.init).sorted {
            ($0.priority.sortRank, $0.number) < ($1.priority.sortRank, $1.number)
        }
        let issues = feedbackIssues       // shadow so the rest of the method is unchanged
        let priorByNumber = Dictionary(uniqueKeysWithValues: allIssues.map { ($0.number, $0) })
        let cloudTranslations = fetchCloudTranslationsByNumber(for: issues.map(\.number))
        allIssues = issues.map { fresh in
            var merged = fresh
            if let prior = priorByNumber[fresh.number] {
                merged.detectedLanguageCode = fresh.detectedLanguageCode ?? prior.detectedLanguageCode
                merged.translatedTitle = fresh.translatedTitle ?? prior.translatedTitle
                merged.translatedBody = fresh.translatedBody ?? prior.translatedBody
                merged.translationTargetLanguage = fresh.translationTargetLanguage ?? prior.translationTargetLanguage
            }
            // If the local cache lacks a translation for the current target but the
            // cloud-synced IssueTranslation has one (e.g. computed by another device),
            // hydrate from it so iOS can show what the Mac translated.
            if let target = intelligenceSettings?.targetLanguageCode,
               merged.translationTargetLanguage != target,
               let row = cloudTranslations[fresh.number],
               row.targetLanguage == target,
               (row.translatedTitle != nil || row.translatedBody != nil) {
                merged.detectedLanguageCode = merged.detectedLanguageCode ?? row.detectedLanguageCode
                merged.translatedTitle = row.translatedTitle ?? merged.translatedTitle
                merged.translatedBody = row.translatedBody ?? merged.translatedBody
                merged.translationTargetLanguage = target
            }
            return merged
        }
        let numbers = Set(issues.map(\.number))
        if let store = seenStore {
            let toFlush = previouslyLoadedNumbers.subtracting(store.seenNumbers(owner: seenOwner, repo: seenRepo))
            if !toFlush.isEmpty {
                store.markSeenBulk(owner: seenOwner, repo: seenRepo, issueNumbers: Array(toFlush))
            }
            let alreadySeen = store.seenNumbers(owner: seenOwner, repo: seenRepo)
            sessionUnread = numbers.subtracting(alreadySeen)
        } else {
            sessionUnread = []
        }
        previouslyLoadedNumbers = numbers
        startTranslationsIfNeeded()
    }

    func isUnread(_ issue: FeedbackIssue) -> Bool {
        sessionUnread.contains(issue.number)
    }

    func markSeen(_ issue: FeedbackIssue) {
        sessionUnread.remove(issue.number)
        seenStore?.markSeen(owner: seenOwner, repo: seenRepo, issueNumber: issue.number)
    }

    private(set) var intelligenceProvider: IntelligenceProvider?
    private(set) var intelligenceSettings: IntelligenceSettings?
    private var cacheContext: ModelContext?
    /// Source languages the Translation framework reported it can't translate to the
    /// current target. Session-scoped: a transient verdict not worth persisting, and
    /// reset on a target-language change so the new target gets a fresh evaluation.
    private(set) var unsupportedSourceLanguages: Set<String> = []

    struct TranslationRequest: Identifiable, Equatable {
        /// Per-enqueue identity. A second enqueue for the same issue (e.g. after
        /// `forceRetranslate`) produces a distinct `requestID` so a late-arriving result
        /// from the first enqueue can be distinguished from a fresh one and dropped.
        let requestID: UUID
        let issueNumber: Int
        let title: String
        let body: String
        let detected: String
        let target: String
        var id: UUID { requestID }
    }

    /// A (source → target) translation language pair. Modeled in full (not just the
    /// source) so a mid-session target switch is tracked correctly.
    struct LanguagePair: Hashable {
        let detected: String
        let target: String
    }

    /// Framework-agnostic mirror of `Translation.LanguageAvailability.Status`, so the
    /// gating decision can be unit-tested without the Translation framework.
    enum LanguageDownloadState {
        case installed     // both languages on-device; translate silently
        case supported     // supported but not downloaded; needs a user-approved download
        case unsupported   // not translatable at all
    }

    /// What `TranslationHost` should do with a pending request given its pair's state.
    enum PumpDecision: Equatable {
        case proceed        // start the session (installed, or user approved the download)
        case needsDownload  // gate: surface the inline download affordance, don't start yet
        case unavailable    // blacklist the language via handleTranslationUnavailable
    }

    private(set) var pendingTranslations: [TranslationRequest] = []
    /// Pairs that are supported but not downloaded and are awaiting the user's tap.
    /// Drives the per-issue "download to translate" affordance.
    private(set) var pairsNeedingDownload: Set<LanguagePair> = []
    /// Pairs the user explicitly approved downloading; lets `pumpDecision` proceed past
    /// the `.supported` gate so the session starts and the system sheet appears.
    private var approvedDownloadPairs: Set<LanguagePair> = []
    /// Bumped on each approval so `TranslationHost` re-pumps the queue.
    private(set) var downloadApprovalTick: Int = 0

    /// Issue numbers granted a one-shot bypass of `unsupportedSourceLanguages` by
    /// `forceRetranslate`. Consumed by `startTranslationsIfNeeded` so the retry runs
    /// for this issue only — without un-blacklisting the language for every other
    /// issue the Translation framework already said it can't handle.
    private var forcedRetranslateNumbers: Set<Int> = []

    /// An issue is "translating" while it sits in the queue actively being processed —
    /// i.e. enqueued and not parked behind a pending language download. (A download-gated
    /// request shows the inline download affordance instead; see `needsLanguageDownload`.)
    func isTranslating(_ issue: FeedbackIssue) -> Bool {
        pendingTranslations.contains { $0.issueNumber == issue.number }
            && needsLanguageDownload(issue) == nil
    }

    /// Returns a write target for the rolling 30-day summary cache, or nil when
    /// caching shouldn't apply (no context attached, missing repo identity, or
    /// transient per-device filters are active).
    func summaryCacheBinding(targetLanguage: String) -> SummaryCacheBinding? {
        guard let cacheContext,
              appFilter.isEmpty, filters.isEmpty,
              !seenOwner.isEmpty, !seenRepo.isEmpty else { return nil }
        return SummaryCacheBinding(
            scope: SummaryCacheScope(
                repoOwner: seenOwner,
                repoName: seenRepo,
                targetLanguage: targetLanguage
            ),
            context: cacheContext
        )
    }

    func attachIntelligence(
        provider: IntelligenceProvider,
        settings: IntelligenceSettings,
        cacheContext: ModelContext
    ) {
        self.intelligenceProvider = provider
        self.intelligenceSettings = settings
        self.cacheContext = cacheContext
    }

    /// Clears local + cloud translation state for one issue and kicks off a fresh translate.
    /// Useful for debugging the translation pipeline when a cached result already exists.
    func forceRetranslate(issueNumber: Int) {
        pendingTranslations.removeAll { $0.issueNumber == issueNumber }

        if let idx = allIssues.firstIndex(where: { $0.number == issueNumber }) {
            // Grant a one-shot bypass for this specific issue instead of removing the
            // language from `unsupportedSourceLanguages`. Removing it would unblock every
            // other issue in that language and cause repeated re-blacklist storms on the
            // next sync.
            forcedRetranslateNumbers.insert(issueNumber)
            allIssues[idx].translatedTitle = nil
            allIssues[idx].translatedBody = nil
            allIssues[idx].translationTargetLanguage = nil
            allIssues[idx].detectedLanguageCode = nil
        }

        if let context = cacheContext {
            let owner = seenOwner
            let repo = seenRepo
            let cachedDescriptor = FetchDescriptor<CachedIssue>(predicate: #Predicate { cached in
                cached.repoOwner == owner && cached.repoName == repo && cached.number == issueNumber
            })
            if let cached = try? context.fetch(cachedDescriptor).first {
                cached.translatedTitle = nil
                cached.translatedBody = nil
                cached.translationTargetLanguage = nil
                cached.detectedLanguageCode = nil
            }
            let cloudDescriptor = FetchDescriptor<IssueTranslation>(predicate: #Predicate { row in
                row.repoOwner == owner && row.repoName == repo && row.number == issueNumber
            })
            for row in (try? context.fetch(cloudDescriptor)) ?? [] {
                context.delete(row)
            }
            try? context.save()
        }

        startTranslationsIfNeeded()
    }

    /// Enqueues every eligible issue for translation by the Translation framework
    /// (driven by `TranslationHost`). No Apple Intelligence dependency — gated only on
    /// the user's translation setting. Per-language-pair availability (installed /
    /// needs-download / unsupported) is resolved downstream by the host via `pumpDecision`.
    func startTranslationsIfNeeded() {
        guard let settings = intelligenceSettings, settings.translationEnabled else { return }

        let target = settings.targetLanguageCode
        for i in allIssues.indices {
            if allIssues[i].translationTargetLanguage == target { continue }
            // Already queued (or in flight in the host): skip without consuming a bypass.
            if pendingTranslations.contains(where: { $0.issueNumber == allIssues[i].number }) { continue }

            if allIssues[i].detectedLanguageCode == nil {
                let combined = allIssues[i].title + "\n" + allIssues[i].description
                allIssues[i].detectedLanguageCode = LanguageDetector.detect(combined) ?? ""
            }
            let issueNumber = allIssues[i].number
            let isForced = forcedRetranslateNumbers.contains(issueNumber)
            // Source detection is now the single source of truth (the framework needs an
            // explicit source language). Skip undetectable, same-language, and blacklisted.
            guard let detected = allIssues[i].detectedLanguageCode, !detected.isEmpty,
                  !detected.hasPrefix(target),
                  isForced || !unsupportedSourceLanguages.contains(detected) else { continue }

            // Consume the one-shot bypass exactly when we commit to enqueuing. Leaving
            // it set across a no-op pass would let a later, unrelated translate-cycle
            // accidentally bypass the language guard.
            if isForced { forcedRetranslateNumbers.remove(issueNumber) }

            enqueueTranslation(for: allIssues[i], detected: detected, target: target)
        }
    }

    @MainActor
    func applyTranslation(_ request: TranslationRequest, title: String?, body: String?) {
        // Match by requestID: if `forceRetranslate` (or a target switch) cleared this
        // request from the queue between drain dispatch and resume, the entry is gone
        // and we must NOT write its stale output. A new enqueue gets a fresh requestID,
        // so an identical-looking re-enqueue won't match either.
        guard pendingTranslations.contains(where: { $0.requestID == request.requestID }) else { return }
        pendingTranslations.removeAll { $0.requestID == request.requestID }
        guard title != nil || body != nil else { return }
        commitTranslation(
            issueNumber: request.issueNumber,
            detected: request.detected,
            title: title,
            body: body,
            target: request.target
        )
    }

    /// Resolves a finished `TranslationHost` drain step into the right state change,
    /// keeping the host a thin driver and the decision unit-testable. The order matters:
    /// a transient error is handled FIRST so a partial result (e.g. the title translated
    /// but the body's `session.translate` was cancelled mid-issue) is discarded rather
    /// than committed. Committing a partial would stamp `translationTargetLanguage` and
    /// freeze the issue with a translated title and the body stranded in its original
    /// language under a "translated" label, never retried (#381).
    @MainActor
    func applyTranslationOutcome(
        _ request: TranslationRequest,
        title: String?,
        body: String?,
        transientError: Bool
    ) {
        if transientError {
            dropPendingRequest(request)
        } else if title != nil || body != nil {
            applyTranslation(request, title: title, body: body)
        } else {
            markLanguageUnsupported(detectedLanguage: request.detected)
        }
    }

    /// Called by `TranslationHost` when the Translation framework reports the
    /// (detected → target) pair genuinely unsupported. Blacklist the source language for
    /// the session so we stop retrying every issue in it. (Pairs that merely need a
    /// download are gated upstream via `pumpDecision`/`needsLanguageDownload`, never here.)
    @MainActor
    func handleTranslationUnavailable(_ request: TranslationRequest) {
        markLanguageUnsupported(detectedLanguage: request.detected)
    }

    /// Decides what `TranslationHost` does with `request` given its pair's availability.
    /// A `.supported` pair proceeds only if the user has approved its download.
    func pumpDecision(for request: TranslationRequest, state: LanguageDownloadState) -> PumpDecision {
        switch state {
        case .unsupported:
            return .unavailable
        case .installed:
            return .proceed
        case .supported:
            let pair = LanguagePair(detected: request.detected, target: request.target)
            return approvedDownloadPairs.contains(pair) ? .proceed : .needsDownload
        }
    }

    /// Records the user's consent to download `detected`→`target`, clears any pending
    /// gate for it, and nudges the host (via `downloadApprovalTick`) to re-pump.
    func approveLanguageDownload(detected: String, target: String) {
        let pair = LanguagePair(detected: detected, target: target)
        pairsNeedingDownload.remove(pair)
        approvedDownloadPairs.insert(pair)
        downloadApprovalTick &+= 1
    }

    /// Marks a `detected`→`target` pair as needing a user-approved download. Called by
    /// the host when availability reports `.supported` for a pair the user hasn't approved.
    func markNeedsDownload(detected: String, target: String) {
        pairsNeedingDownload.insert(LanguagePair(detected: detected, target: target))
    }

    /// The source-language display name to prompt the user to download for `issue`, or
    /// nil if it isn't gated on a download (no pending request, or already approved).
    func needsLanguageDownload(_ issue: FeedbackIssue) -> String? {
        guard let req = pendingTranslations.first(where: { $0.issueNumber == issue.number }) else { return nil }
        let pair = LanguagePair(detected: req.detected, target: req.target)
        guard pairsNeedingDownload.contains(pair) else { return nil }
        return Locale.current.localizedString(forLanguageCode: req.detected) ?? req.detected
    }

    /// Convenience for the card: resolves `issue` to its pending pair and approves it.
    func approveLanguageDownload(for issue: FeedbackIssue) {
        guard let req = pendingTranslations.first(where: { $0.issueNumber == issue.number }) else { return }
        approveLanguageDownload(detected: req.detected, target: req.target)
    }

    /// Re-gates a previously-approved pair — used when the user dismissed the system
    /// download sheet without downloading, so the inline prompt reappears.
    func regateDownload(detected: String, target: String) {
        let pair = LanguagePair(detected: detected, target: target)
        approvedDownloadPairs.remove(pair)
        pairsNeedingDownload.insert(pair)
    }

    /// The first pending request eligible to pump now: one whose pair is not currently
    /// gated awaiting a download. Approving a pair removes it from `pairsNeedingDownload`,
    /// so approved pairs are eligible again.
    func nextPumpableRequest() -> TranslationRequest? {
        pendingTranslations.first { req in
            !pairsNeedingDownload.contains(LanguagePair(detected: req.detected, target: req.target))
        }
    }

    /// Removes a single pending request without blacklisting its language.
    /// Used when the Translation framework threw a transient error (network,
    /// cancellation) so the queue can keep draining without poisoning the
    /// whole language for the session.
    @MainActor
    func dropPendingRequest(_ request: TranslationRequest) {
        // Same currency check as `applyTranslation` — a cancelled request shouldn't
        // stamp `translationTargetLanguage`, since a fresh translate may already be
        // in flight.
        guard pendingTranslations.contains(where: { $0.requestID == request.requestID }) else { return }
        pendingTranslations.removeAll { $0.requestID == request.requestID }
        // Stamp in-memory only (persist: false): suppress a tight in-session retry loop,
        // but leave the SwiftData cache un-stamped so a transient/guardrail failure is
        // retried on the next launch instead of being permanently frozen.
        recordAttempted(issueNumber: request.issueNumber, target: request.target, persist: false)
    }

    @MainActor
    func markLanguageUnsupported(detectedLanguage: String) {
        unsupportedSourceLanguages.insert(detectedLanguage)
        let drained = pendingTranslations.filter { $0.detected == detectedLanguage }
        pendingTranslations.removeAll { $0.detected == detectedLanguage }
        let indexByNumber = Dictionary(uniqueKeysWithValues: allIssues.enumerated().map { ($1.number, $0) })
        for req in drained {
            // Stamp each request with the target IT was enqueued for. Using a single
            // caller-supplied target would record "attempted at <current target>" for
            // requests that were enqueued under an earlier target — locking them out of
            // a retry at the target they were actually meant for.
            if let idx = indexByNumber[req.issueNumber] {
                allIssues[idx].translationTargetLanguage = req.target
            }
            if let context = cacheContext {
                markTranslationAttempt(issueNumber: req.issueNumber, target: req.target, context: context)
            }
        }
    }

    /// Records a successful translation in-memory and in the SwiftData cache.
    /// Shared by the on-device path and the Translation-framework fallback so
    /// persistence stays in lock-step if its shape changes.
    ///
    /// Merge semantics: a nil `title`/`body` parameter means "this side wasn't
    /// translated this round" — keep the prior value. Without this, a partial
    /// success (title translated, body errored) would wipe a previously-good body
    /// translation (including one hydrated from CloudKit via `applyLoaded`).
    @MainActor
    private func commitTranslation(issueNumber: Int, detected: String, title: String?, body: String?, target: String) {
        // An empty/whitespace-only result is not a translation — the fallback's NMT model
        // can return "" for content it won't translate. Never store it (it would render a
        // blank field under a "translated" label); fall back to the original instead.
        let title = title.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        let body = body.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        if let idx = allIssues.firstIndex(where: { $0.number == issueNumber }) {
            allIssues[idx].detectedLanguageCode = detected
            if let title { allIssues[idx].translatedTitle = title }
            if let body { allIssues[idx].translatedBody = body }
            allIssues[idx].translationTargetLanguage = target
        }
        if let context = cacheContext {
            persistTranslation(
                issueNumber: issueNumber,
                detected: detected,
                title: title,
                body: body,
                target: target,
                context: context
            )
        }
    }

    /// Marks an issue as having been attempted for this target language so
    /// `startTranslationsIfNeeded` won't retry it. Used when translation
    /// failed but the source language itself isn't being blacklisted.
    @MainActor
    private func recordAttempted(issueNumber: Int, target: String, persist: Bool = true) {
        if let idx = allIssues.firstIndex(where: { $0.number == issueNumber }) {
            allIssues[idx].translationTargetLanguage = target
        }
        if persist, let context = cacheContext {
            markTranslationAttempt(issueNumber: issueNumber, target: target, context: context)
        }
    }

    @MainActor
    private func enqueueTranslation(for issue: FeedbackIssue, detected: String, target: String) {
        guard !pendingTranslations.contains(where: { $0.issueNumber == issue.number }) else { return }
        pendingTranslations.append(TranslationRequest(
            requestID: UUID(),
            issueNumber: issue.number,
            title: issue.title,
            body: issue.description,
            detected: detected,
            target: target
        ))
    }

    private func markTranslationAttempt(
        issueNumber: Int,
        target: String,
        context: ModelContext
    ) {
        let owner = seenOwner
        let repo = seenRepo
        let descriptor = FetchDescriptor<CachedIssue>(predicate: #Predicate { cached in
            cached.repoOwner == owner && cached.repoName == repo && cached.number == issueNumber
        })
        if let existing = try? context.fetch(descriptor).first {
            existing.translationTargetLanguage = target
            try? context.save()
        }
    }

    private func persistTranslation(
        issueNumber: Int,
        detected: String,
        title: String?,
        body: String?,
        target: String,
        context: ModelContext
    ) {
        let owner = seenOwner
        let repo = seenRepo
        let descriptor = FetchDescriptor<CachedIssue>(predicate: #Predicate { cached in
            cached.repoOwner == owner && cached.repoName == repo && cached.number == issueNumber
        })
        if let existing = try? context.fetch(descriptor).first {
            existing.detectedLanguageCode = detected
            if let title { existing.translatedTitle = title }
            if let body { existing.translatedBody = body }
            existing.translationTargetLanguage = target
            try? context.save()
        }
        upsertCloudTranslation(
            issueNumber: issueNumber,
            detected: detected,
            title: title,
            body: body,
            target: target,
            context: context
        )
    }

    /// Upserts the cloud-synced translation row for `(owner, repo, number, target)`.
    /// CloudKit propagates this to other devices so a translation produced on one device
    /// (e.g. Mac with Apple Intelligence) appears on devices that lack on-device models.
    private func upsertCloudTranslation(
        issueNumber: Int,
        detected: String,
        title: String?,
        body: String?,
        target: String,
        context: ModelContext
    ) {
        let owner = seenOwner
        let repo = seenRepo
        let descriptor = FetchDescriptor<IssueTranslation>(predicate: #Predicate { row in
            row.repoOwner == owner && row.repoName == repo && row.number == issueNumber
                && row.targetLanguage == target
        })
        if let row = (try? context.fetch(descriptor))?.first {
            row.detectedLanguageCode = detected
            // Same merge semantics as `commitTranslation`: don't clobber a previously
            // good translation with nil when the current pass only filled one side.
            if let title { row.translatedTitle = title }
            if let body { row.translatedBody = body }
            row.updatedAt = Date()
        } else {
            context.insert(IssueTranslation(
                repoOwner: owner,
                repoName: repo,
                number: issueNumber,
                targetLanguage: target,
                detectedLanguageCode: detected,
                translatedTitle: title,
                translatedBody: body
            ))
        }
        try? context.save()
    }

    /// Bulk-fetches IssueTranslation rows for the current target language and the given
    /// issue numbers, returning a number → row map. Returns empty when no context, no
    /// settings, or translations are disabled. Used by `applyLoaded` to hydrate translations
    /// that arrived via CloudKit without a local re-translation.
    private func fetchCloudTranslationsByNumber(for numbers: [Int]) -> [Int: IssueTranslation] {
        guard !numbers.isEmpty,
              let context = cacheContext,
              let settings = intelligenceSettings,
              settings.translationEnabled else { return [:] }
        let owner = seenOwner
        let repo = seenRepo
        let target = settings.targetLanguageCode
        let numberSet = Set(numbers)
        let descriptor = FetchDescriptor<IssueTranslation>(predicate: #Predicate { row in
            row.repoOwner == owner && row.repoName == repo
                && row.targetLanguage == target
                && numberSet.contains(row.number)
        })
        let rows = (try? context.fetch(descriptor)) ?? []
        return Dictionary(rows.map { ($0.number, $0) }, uniquingKeysWith: { older, newer in
            newer.updatedAt > older.updatedAt ? newer : older
        })
    }

    func invalidateTranslations() {
        // Drop everything queued for the old target so a late result can't commit onto a
        // re-translation, and reset the per-pair download gating + session blacklist so a
        // target switch re-evaluates language support against the new target.
        pendingTranslations.removeAll()
        pairsNeedingDownload.removeAll()
        approvedDownloadPairs.removeAll()
        unsupportedSourceLanguages.removeAll()
        forcedRetranslateNumbers.removeAll()
        for i in allIssues.indices {
            allIssues[i].translatedTitle = nil
            allIssues[i].translatedBody = nil
            allIssues[i].translationTargetLanguage = nil
        }
        if let context = cacheContext {
            let owner = seenOwner
            let repo = seenRepo
            let descriptor = FetchDescriptor<CachedIssue>(predicate: #Predicate { cached in
                cached.repoOwner == owner && cached.repoName == repo
                    && cached.translationTargetLanguage != nil
            })
            if let rows = try? context.fetch(descriptor) {
                for row in rows {
                    row.translatedTitle = nil
                    row.translatedBody = nil
                    row.translationTargetLanguage = nil
                }
                try? context.save()
            }
        }
    }
}

extension Set {
    mutating func toggleMembership(_ element: Element) {
        if contains(element) { remove(element) } else { insert(element) }
    }
}
