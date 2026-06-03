import Foundation
import SwiftData
import Observation

@MainActor
@Observable
final class GitHubAccountStore {
    private(set) var accounts: [GitHubAccount] = []

    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
        self.accounts = Self.fetch(in: context)
    }

    func account(id: UUID) -> GitHubAccount? {
        accounts.first(where: { $0.id == id })
    }

    /// The OAuth token for this account, from iCloud Keychain. Synchronous so views can
    /// read it inline when prefilling the Add form.
    func token(for account: GitHubAccount) -> String? {
        KeychainService.loadGitHubTokenSync(for: account.id)
    }

    /// Inserts a new account or, if one with the same login (case-insensitive) already
    /// exists, refreshes its avatar + token in place. This is also the Reconnect path.
    @discardableResult
    func add(login: String, avatarURL: String?, token: String) async -> GitHubAccount {
        let trimmed = login.trimmingCharacters(in: .whitespaces)
        let target: GitHubAccount
        if let existing = accounts.first(where: { $0.login.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            existing.avatarURL = avatarURL
            target = existing
        } else {
            let new = GitHubAccount(login: trimmed, avatarURL: avatarURL)
            context.insert(new)
            target = new
        }
        save()
        reload()  // optimistic — observers see the new/updated row immediately
        _ = await KeychainService.saveGitHubToken(token, for: target.id)
        reload()  // refresh after the keychain write (no-op if rows unchanged)
        return account(id: target.id) ?? target
    }

    /// Removes the account row and its Keychain token. Already-added repos keep their own
    /// per-repo token copies and are unaffected.
    func deleteWithCredentials(_ account: GitHubAccount) async {
        let id = account.id
        await KeychainService.deleteGitHubToken(for: id)
        context.delete(account)
        save()
        reload()
    }

    func reload() {
        accounts = Self.fetch(in: context)
    }

    private func save() {
        guard context.hasChanges else { return }
        do {
            try context.save()
        } catch {
            assertionFailure("GitHubAccountStore save failed: \(error)")
        }
    }

    private static func fetch(in context: ModelContext) -> [GitHubAccount] {
        let descriptor = FetchDescriptor<GitHubAccount>(
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )
        let rows = (try? context.fetch(descriptor)) ?? []
        return coalesce(rows, in: context)
    }

    /// Collapses duplicate rows produced by CloudKit syncing the same account across
    /// devices. Duplicates share a login (case-insensitive); the oldest wins. Empty-login
    /// rows (aborted connects) are dropped when any non-empty row exists. Idempotent.
    private static func coalesce(_ rows: [GitHubAccount], in context: ModelContext) -> [GitHubAccount] {
        var winners: [GitHubAccount] = []
        var winnersByLogin: [String: GitHubAccount] = [:]
        var toDelete: [GitHubAccount] = []

        let hasAnyNonEmpty = rows.contains { !$0.login.trimmingCharacters(in: .whitespaces).isEmpty }

        for row in rows {
            let trimmed = row.login.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                if hasAnyNonEmpty { toDelete.append(row) } else { winners.append(row) }
                continue
            }
            let key = trimmed.lowercased()
            if winnersByLogin[key] == nil {
                winnersByLogin[key] = row
                winners.append(row)
            } else {
                toDelete.append(row)
            }
        }

        guard !toDelete.isEmpty else { return winners }
        for row in toDelete { context.delete(row) }
        try? context.save()
        return winners
    }
}
