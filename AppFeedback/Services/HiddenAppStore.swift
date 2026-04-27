import Foundation
import SwiftData

@MainActor
final class HiddenAppStore {
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    /// All hidden app names for a repo, sorted as a Set for membership checks.
    func hiddenApps(owner: String, repo: String) -> Set<String> {
        let predicate = #Predicate<HiddenApp> {
            $0.repoOwner == owner && $0.repoName == repo
        }
        let descriptor = FetchDescriptor<HiddenApp>(predicate: predicate)
        let rows = (try? context.fetch(descriptor)) ?? []
        return Set(rows.map(\.appName))
    }

    /// Idempotent: skips if already hidden.
    func hide(owner: String, repo: String, appName: String) {
        guard !exists(owner: owner, repo: repo, appName: appName) else { return }
        context.insert(HiddenApp(repoOwner: owner, repoName: repo, appName: appName))
        try? context.save()
    }

    /// Removes all HiddenApp rows for the (owner, repo).
    func unhideAll(owner: String, repo: String) {
        let predicate = #Predicate<HiddenApp> {
            $0.repoOwner == owner && $0.repoName == repo
        }
        guard let rows = try? context.fetch(FetchDescriptor<HiddenApp>(predicate: predicate)),
              !rows.isEmpty else { return }
        for row in rows { context.delete(row) }
        try? context.save()
    }

    /// One-time best-effort migration: copies legacy [String] hiddenAppNames into HiddenApp rows
    /// for any repo that doesn't already have HiddenApp rows. Safe to call multiple times.
    func migrateLegacy(owner: String, repo: String, legacyNames: [String]) {
        guard !legacyNames.isEmpty else { return }
        let existing = hiddenApps(owner: owner, repo: repo)
        var inserted = false
        for name in legacyNames where !existing.contains(name) {
            context.insert(HiddenApp(repoOwner: owner, repoName: repo, appName: name))
            inserted = true
        }
        if inserted { try? context.save() }
    }

    private func exists(owner: String, repo: String, appName: String) -> Bool {
        let predicate = #Predicate<HiddenApp> {
            $0.repoOwner == owner && $0.repoName == repo && $0.appName == appName
        }
        var descriptor = FetchDescriptor<HiddenApp>(predicate: predicate)
        descriptor.fetchLimit = 1
        return ((try? context.fetch(descriptor))?.first) != nil
    }
}
