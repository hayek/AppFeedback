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
    /// Selected feedback sources. Default = all-on (every case). Persisted as a
    /// `[String]` of raw values so it stays CloudKit/JSON-friendly; an absent key
    /// in legacy JSON decodes back to all-on (so existing rows keep all sources).
    var sources: Set<FeedbackSource> = Set(FeedbackSource.allCases)

    enum CodingKeys: String, CodingKey {
        case appVersion, device, osVersion, issueType, appFilter, sources
    }

    init(
        appVersion: Set<String> = [],
        device: Set<String> = [],
        osVersion: Set<String> = [],
        issueType: Set<IssueType> = [],
        appFilter: Set<String> = [],
        sources: Set<FeedbackSource> = Set(FeedbackSource.allCases)
    ) {
        self.appVersion = appVersion
        self.device = device
        self.osVersion = osVersion
        self.issueType = issueType
        self.appFilter = appFilter
        self.sources = sources
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        appVersion = try c.decodeIfPresent(Set<String>.self, forKey: .appVersion) ?? []
        device = try c.decodeIfPresent(Set<String>.self, forKey: .device) ?? []
        osVersion = try c.decodeIfPresent(Set<String>.self, forKey: .osVersion) ?? []
        issueType = try c.decodeIfPresent(Set<IssueType>.self, forKey: .issueType) ?? []
        appFilter = try c.decodeIfPresent(Set<String>.self, forKey: .appFilter) ?? []
        let raw = try c.decodeIfPresent([String].self, forKey: .sources)
        if let raw {
            sources = Set(raw.compactMap(FeedbackSource.init(rawValue:)))
        } else {
            sources = Set(FeedbackSource.allCases)   // legacy JSON ⇒ all-on
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(appVersion, forKey: .appVersion)
        try c.encode(device, forKey: .device)
        try c.encode(osVersion, forKey: .osVersion)
        try c.encode(issueType, forKey: .issueType)
        try c.encode(appFilter, forKey: .appFilter)
        try c.encode(sources.map(\.rawValue).sorted(), forKey: .sources)
    }
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
