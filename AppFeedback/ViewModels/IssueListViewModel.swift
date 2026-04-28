import Foundation
import Observation
import SwiftData

@Observable @MainActor
final class IssueListViewModel {
    var allIssues: [FeedbackIssue] = []

    var unreadIssues: [FeedbackIssue] {
        allIssues.filter { sessionUnread.contains($0.number) }
    }
    var searchQuery = ""
    var appFilter: String? = nil
    var allowsAppFilter: Bool = false
    var filters = ActiveFilters()

    var uniqueAppNames: [String] {
        Array(Set(allIssues.compactMap(\.appName))).sorted()
    }

    struct ActiveFilters {
        var appVersion: String? = nil
        var device: String? = nil
        var osVersion: String? = nil
        var issueType: IssueType? = nil

        var isEmpty: Bool { appVersion == nil && device == nil && osVersion == nil && issueType == nil }
    }

    var visibleIssues: [FeedbackIssue] {
        var list = allIssues

        if let app = appFilter {
            list = list.filter { $0.appName == app }
        }
        if let v = filters.appVersion { list = list.filter { $0.appVersion == v } }
        if let d = filters.device     { list = list.filter { $0.device == d } }
        if let o = filters.osVersion  { list = list.filter { $0.osVersion == o } }
        if let t = filters.issueType  { list = list.filter { $0.labels.issueType?.type == t } }

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
        let base = appFilter.map { app in allIssues.filter { $0.appName == app } } ?? allIssues
        let types = base.compactMap { $0.labels.issueType?.type }
        return Array(Set(types)).sorted { $0.displayName < $1.displayName }
    }

    func uniqueValues(for keyPath: KeyPath<FeedbackIssue, String?>) -> [String] {
        let base = appFilter.map { app in allIssues.filter { $0.appName == app } } ?? allIssues
        return Array(Set(base.compactMap { $0[keyPath: keyPath] })).sorted()
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
        allIssues = issues.map { fresh in
            guard let prior = priorByNumber[fresh.number] else { return fresh }
            var merged = fresh
            merged.detectedLanguageCode = fresh.detectedLanguageCode ?? prior.detectedLanguageCode
            merged.translatedTitle = fresh.translatedTitle ?? prior.translatedTitle
            merged.translatedBody = fresh.translatedBody ?? prior.translatedBody
            merged.translationTargetLanguage = fresh.translationTargetLanguage ?? prior.translationTargetLanguage
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

    func attachIntelligence(
        provider: IntelligenceProvider,
        settings: IntelligenceSettings,
        cacheContext: ModelContext
    ) {
        self.intelligenceProvider = provider
        self.intelligenceSettings = settings
        self.cacheContext = cacheContext
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
            translationTasks[issue.number] = Task { [weak self] in
                await self?.translate(issue: issue, detected: detected, target: target)
            }
        }
    }

    @MainActor
    private func translate(issue: FeedbackIssue, detected: String, target: String) async {
        defer { translationTasks[issue.number] = nil }
        guard let provider = intelligenceProvider else { return }
        do {
            async let titleT = provider.translate(text: issue.title, from: detected, to: target)
            async let bodyT = provider.translate(text: issue.description, from: detected, to: target)
            let (newTitle, newBody) = try await (titleT, bodyT)
            try Task.checkCancellation()

            if let idx = allIssues.firstIndex(where: { $0.number == issue.number }) {
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
        } catch {
            if let idx = allIssues.firstIndex(where: { $0.number == issue.number }) {
                allIssues[idx].translationTargetLanguage = target
            }
            if let context = cacheContext {
                markTranslationAttempt(issueNumber: issue.number, target: target, context: context)
            }
        }
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
        title: String,
        body: String,
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
    }

    func invalidateTranslations() {
        for (_, task) in translationTasks { task.cancel() }
        translationTasks.removeAll()
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
