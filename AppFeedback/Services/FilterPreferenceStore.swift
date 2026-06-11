import Foundation
import SwiftData

// MARK: - Persisted DTOs (no `search` — live search is intentionally not persisted)

struct PersistedTaskFilters: Codable, Equatable {
    var statuses: Set<TaskStatus> = []
    var priorities: Set<TaskPriority> = []
    var versionScope: VersionScope = .any
}

struct PersistedVersionFilters: Codable, Equatable {
    var states: Set<VersionState> = []
}

struct PersistedFeedbackFilters: Codable, Equatable {
    var appVersion: Set<String> = []
    var device: Set<String> = []
    var osVersion: Set<String> = []
    var issueType: Set<IssueType> = []
    var appFilter: Set<String> = []
}

struct PersistedFilterBundle: Codable, Equatable {
    var task = PersistedTaskFilters()
    var version = PersistedVersionFilters()
    var feedback = PersistedFeedbackFilters()
}

// MARK: - Store

@MainActor
final class FilterPreferenceStore {
    private let context: ModelContext
    init(context: ModelContext) { self.context = context }

    func load(owner: String, repo: String) -> PersistedFilterBundle {
        guard let row = row(owner: owner, repo: repo) else { return PersistedFilterBundle() }
        return PersistedFilterBundle(
            task: decode(row.taskFiltersData) ?? PersistedTaskFilters(),
            version: decode(row.versionFiltersData) ?? PersistedVersionFilters(),
            feedback: decode(row.feedbackFiltersData) ?? PersistedFeedbackFilters()
        )
    }

    func save(owner: String, repo: String, bundle: PersistedFilterBundle) {
        let row = row(owner: owner, repo: repo) ?? {
            let created = RepoFilterPreference(repoOwner: owner, repoName: repo)
            context.insert(created)
            return created
        }()
        row.taskFiltersData = encode(bundle.task)
        row.versionFiltersData = encode(bundle.version)
        row.feedbackFiltersData = encode(bundle.feedback)
        row.updatedAt = Date()
        try? context.save()
    }

    private func row(owner: String, repo: String) -> RepoFilterPreference? {
        let predicate = #Predicate<RepoFilterPreference> { $0.repoOwner == owner && $0.repoName == repo }
        var descriptor = FetchDescriptor<RepoFilterPreference>(predicate: predicate)
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    private func encode<T: Encodable>(_ value: T) -> Data? { try? JSONEncoder().encode(value) }
    private func decode<T: Decodable>(_ data: Data?) -> T? {
        data.flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }
}
