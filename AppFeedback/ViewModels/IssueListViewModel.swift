import Foundation
import Observation

@Observable @MainActor
final class IssueListViewModel {
    var allIssues: [FeedbackIssue] = []
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
    }

    func isUnread(_ issue: FeedbackIssue) -> Bool {
        sessionUnread.contains(issue.number)
    }

    func markSeen(_ issue: FeedbackIssue) {
        sessionUnread.remove(issue.number)
        seenStore?.markSeen(owner: seenOwner, repo: seenRepo, issueNumber: issue.number)
    }
}
