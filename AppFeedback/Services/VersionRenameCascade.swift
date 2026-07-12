import Foundation
import SwiftData

/// Rewrites the local, name-keyed references to a version that has just been renamed.
///
/// GitHub needs no repair — its issues are attached to the milestone by *number*, which a rename
/// doesn't change — so this is a purely local fixup and needs no network reconcile. It covers the
/// two persisted copies of the name that `VersionStore.rename` does not own:
///
/// - `CachedIssue.milestoneTitle`, the local mirror that rehydrates `TaskItem.milestoneTitle`
///   (the app never learns milestone *numbers* for issues: `IssueLoader` selects only
///   `milestone { title }`), so without this every task detaches from the version until a full
///   reconcile — which the default incremental refresh never performs.
/// - The `VersionScope.versions` set inside the persisted task filters, which would otherwise pin a
///   name that no longer exists and silently match nothing.
@MainActor
struct VersionRenameCascade {
    let cacheContext: ModelContext
    let filterStore: FilterPreferenceStore

    func apply(owner: String, repo: String, from oldName: String, to newName: String) {
        guard oldName != newName else { return }
        rewriteCachedIssues(owner: owner, repo: repo, from: oldName, to: newName)
        rewritePersistedFilters(owner: owner, repo: repo, from: oldName, to: newName)
    }

    private func rewriteCachedIssues(owner: String, repo: String, from oldName: String, to newName: String) {
        let predicate = #Predicate<CachedIssue> {
            $0.repoOwner == owner && $0.repoName == repo && $0.milestoneTitle == oldName
        }
        guard let stale = try? cacheContext.fetch(FetchDescriptor<CachedIssue>(predicate: predicate)),
              !stale.isEmpty else { return }
        for issue in stale { issue.milestoneTitle = newName }
        try? cacheContext.save()
    }

    private func rewritePersistedFilters(owner: String, repo: String, from oldName: String, to newName: String) {
        var bundle = filterStore.load(owner: owner, repo: repo)
        guard case .versions(var names) = bundle.task.versionScope, names.contains(oldName) else { return }
        names.remove(oldName)
        names.insert(newName)
        bundle.task.versionScope = .versions(names)
        filterStore.save(owner: owner, repo: repo, bundle: bundle)
    }
}
