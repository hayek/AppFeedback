import Foundation
import Observation

@Observable @MainActor
final class IssueListViewModel {
    var allIssues: [FeedbackIssue] = []
    var searchQuery = ""
    var sortOrder: SortOrder = .newest
    var appFilter: String? = nil
    var filters = ActiveFilters()

    enum SortOrder { case newest, oldest }

    struct ActiveFilters {
        var appVersion: String? = nil
        var device: String? = nil
        var osVersion: String? = nil

        var isEmpty: Bool { appVersion == nil && device == nil && osVersion == nil }
    }

    var visibleIssues: [FeedbackIssue] {
        var list = allIssues

        if let app = appFilter {
            list = list.filter { $0.appName == app }
        }
        if let v = filters.appVersion { list = list.filter { $0.appVersion == v } }
        if let d = filters.device     { list = list.filter { $0.device == d } }
        if let o = filters.osVersion  { list = list.filter { $0.osVersion == o } }

        if !searchQuery.isEmpty {
            let q = searchQuery.lowercased()
            list = list.filter {
                $0.title.lowercased().contains(q) ||
                $0.description.lowercased().contains(q) ||
                ($0.appName ?? "").lowercased().contains(q) ||
                ($0.email ?? "").lowercased().contains(q)
            }
        }

        return list.sorted {
            sortOrder == .newest ? $0.createdAt > $1.createdAt : $0.createdAt < $1.createdAt
        }
    }

    func uniqueValues(for keyPath: KeyPath<FeedbackIssue, String?>) -> [String] {
        let base = appFilter.map { app in allIssues.filter { $0.appName == app } } ?? allIssues
        return Array(Set(base.compactMap { $0[keyPath: keyPath] })).sorted()
    }

    func clearFilters() {
        filters = ActiveFilters()
    }
}
