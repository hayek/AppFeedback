import XCTest
import SwiftData
@testable import AppFeedback

@MainActor
final class VersionRenameCascadeTests: XCTestCase {
    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let container = try ModelContainer(
            for: CachedIssue.self, RepoFilterPreference.self, configurations: config)
        return ModelContext(container)
    }

    private func cachedIssue(number: Int, owner: String, repo: String, milestone: String?) -> CachedIssue {
        let issue = CachedIssue(
            repoOwner: owner, repoName: repo, number: number, title: "t", createdAt: Date(),
            rawBody: "", appName: nil, appVersion: nil, device: nil, osVersion: nil,
            email: nil, issueDescription: "")
        issue.milestoneTitle = milestone   // not an init parameter — set after construction
        return issue
    }

    func testRewritesCachedIssueMilestoneTitles() throws {
        let context = try makeContext()
        context.insert(cachedIssue(number: 1, owner: "o", repo: "r", milestone: "1.2.0"))
        context.insert(cachedIssue(number: 2, owner: "o", repo: "r", milestone: "9.9"))
        context.insert(cachedIssue(number: 3, owner: "o", repo: "r", milestone: nil))
        try context.save()

        let cascade = VersionRenameCascade(cacheContext: context,
                                           filterStore: FilterPreferenceStore(context: context))
        cascade.apply(owner: "o", repo: "r", from: "1.2.0", to: "1.3.0")

        let all = try context.fetch(FetchDescriptor<CachedIssue>()).sorted { $0.number < $1.number }
        XCTAssertEqual(all.map(\.milestoneTitle), ["1.3.0", "9.9", nil])
    }

    /// A same-named milestone in another product must be untouched.
    func testCachedIssueRewriteIsScopedToItsOwnProduct() throws {
        let context = try makeContext()
        context.insert(cachedIssue(number: 1, owner: "o", repo: "r", milestone: "1.2.0"))
        context.insert(cachedIssue(number: 2, owner: "o", repo: "other", milestone: "1.2.0"))
        try context.save()

        let cascade = VersionRenameCascade(cacheContext: context,
                                           filterStore: FilterPreferenceStore(context: context))
        cascade.apply(owner: "o", repo: "r", from: "1.2.0", to: "1.3.0")

        let all = try context.fetch(FetchDescriptor<CachedIssue>()).sorted { $0.number < $1.number }
        XCTAssertEqual(all.map(\.milestoneTitle), ["1.3.0", "1.2.0"])
    }

    /// A persisted `.versions` filter pinned to the old name must follow the rename, or it silently
    /// matches nothing behind a pill that still reads "1.2.0".
    func testRewritesPersistedVersionScopeFilter() throws {
        let context = try makeContext()
        let filterStore = FilterPreferenceStore(context: context)
        var bundle = PersistedFilterBundle()
        bundle.task = PersistedTaskFilters(versionScope: .versions(["1.2.0", "1.1.0"]))
        filterStore.save(owner: "o", repo: "r", bundle: bundle)

        VersionRenameCascade(cacheContext: context, filterStore: filterStore)
            .apply(owner: "o", repo: "r", from: "1.2.0", to: "1.3.0")

        XCTAssertEqual(filterStore.load(owner: "o", repo: "r").task.versionScope,
                       .versions(["1.3.0", "1.1.0"]))
    }

    /// A filter that doesn't name the renamed version is left exactly as it was.
    func testLeavesUnrelatedFilterScopesAlone() throws {
        let context = try makeContext()
        let filterStore = FilterPreferenceStore(context: context)
        var bundle = PersistedFilterBundle()
        bundle.task = PersistedTaskFilters(versionScope: .state(.wip))
        filterStore.save(owner: "o", repo: "r", bundle: bundle)

        VersionRenameCascade(cacheContext: context, filterStore: filterStore)
            .apply(owner: "o", repo: "r", from: "1.2.0", to: "1.3.0")

        XCTAssertEqual(filterStore.load(owner: "o", repo: "r").task.versionScope, .state(.wip))
    }
}
