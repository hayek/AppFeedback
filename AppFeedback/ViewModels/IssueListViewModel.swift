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

    struct ActiveFilters {
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

    /// All issues with hidden apps filtered out, optionally narrowed to the selected app.
    private var visibleBase: [FeedbackIssue] {
        let withoutHidden = hiddenApps.isEmpty ? allIssues : allIssues.filter { !hiddenApps.contains($0.appName ?? "") }
        return appFilter.isEmpty ? withoutHidden : withoutHidden.filter { appFilter.contains($0.appName ?? "") }
    }

    func clearFilters() {
        filters = ActiveFilters()
    }


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
    private var translationTasks: [Int: Task<Void, Never>] = [:]
    private(set) var translatingNumbers: Set<Int> = []

    func isTranslating(_ issue: FeedbackIssue) -> Bool {
        translatingNumbers.contains(issue.number)
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
        translationTasks[issueNumber]?.cancel()
        translationTasks[issueNumber] = nil
        translatingNumbers.remove(issueNumber)

        if let idx = allIssues.firstIndex(where: { $0.number == issueNumber }) {
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

    func startTranslationsIfNeeded() {
        guard let provider = intelligenceProvider,
              let settings = intelligenceSettings,
              settings.translationEnabled,
              provider.availability.isReady else { return }

        let target = settings.targetLanguageCode
        for i in allIssues.indices {
            if allIssues[i].translationTargetLanguage == target { continue }
            if translationTasks[allIssues[i].number] != nil { continue }

            if allIssues[i].detectedLanguageCode == nil {
                let combined = allIssues[i].title + "\n" + allIssues[i].description
                allIssues[i].detectedLanguageCode = LanguageDetector.detect(combined) ?? ""
            }
            guard let detected = allIssues[i].detectedLanguageCode, !detected.isEmpty,
                  !detected.hasPrefix(target) else { continue }

            let issue = allIssues[i]
            translatingNumbers.insert(issue.number)
            translationTasks[issue.number] = Task { [weak self] in
                await self?.translate(issue: issue, detected: detected, target: target)
            }
        }
    }

    @MainActor
    private func translate(issue: FeedbackIssue, detected: String, target: String) async {
        defer {
            translationTasks[issue.number] = nil
            translatingNumbers.remove(issue.number)
        }
        guard let provider = intelligenceProvider else { return }
        async let titleT = Self.attemptTranslate(provider: provider, text: issue.title, from: detected, to: target)
        async let bodyT = Self.attemptTranslate(provider: provider, text: issue.description, from: detected, to: target)
        let newTitle = await titleT
        let newBody = await bodyT
        guard !Task.isCancelled else { return }

        let idx = allIssues.firstIndex(where: { $0.number == issue.number })

        if newTitle == nil && newBody == nil {
            if let idx { allIssues[idx].translationTargetLanguage = target }
            if let context = cacheContext {
                markTranslationAttempt(issueNumber: issue.number, target: target, context: context)
            }
            return
        }

        if let idx {
            allIssues[idx].detectedLanguageCode = detected
            allIssues[idx].translatedTitle = newTitle
            allIssues[idx].translatedBody = newBody
            allIssues[idx].translationTargetLanguage = target
        }
        if let context = cacheContext {
            persistTranslation(
                issueNumber: issue.number,
                detected: detected,
                title: newTitle,
                body: newBody,
                target: target,
                context: context
            )
        }
    }

    nonisolated private static func attemptTranslate(
        provider: IntelligenceProvider,
        text: String,
        from: String,
        to: String
    ) async -> String? {
        do { return try await provider.translate(text: text, from: from, to: to) }
        catch { return nil }
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
            existing.translatedTitle = title
            existing.translatedBody = body
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
            row.translatedTitle = title
            row.translatedBody = body
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
        for (_, task) in translationTasks { task.cancel() }
        translationTasks.removeAll()
        translatingNumbers.removeAll()
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
