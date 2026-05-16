import Foundation
import SwiftData
import Observation

@MainActor
@Observable
final class MailAccountStore {
    private(set) var accounts: [MailAccount] = []

    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
        self.accounts = Self.fetch(in: context)
    }

    var defaultSender: MailAccount? {
        accounts.first(where: { $0.isDefaultSender }) ?? accounts.first
    }

    func account(id: UUID) -> MailAccount? {
        accounts.first(where: { $0.id == id })
    }

    @discardableResult
    func add(_ mutate: (MailAccount) -> Void = { _ in }) -> MailAccount {
        let new = MailAccount()
        context.insert(new)
        mutate(new)
        if accounts.isEmpty {
            new.isDefaultSender = true
        }
        save()
        reload()
        return account(id: new.id) ?? new
    }

    func update(id: UUID, _ mutate: (MailAccount) -> Void) {
        guard let target = account(id: id) else { return }
        mutate(target)
        save()
    }

    func setDefaultSender(_ target: MailAccount) {
        for acc in accounts {
            let shouldBeDefault = acc.id == target.id
            if acc.isDefaultSender != shouldBeDefault {
                acc.isDefaultSender = shouldBeDefault
            }
        }
        save()
    }

    func delete(_ target: MailAccount) {
        let wasDefault = target.isDefaultSender
        context.delete(target)
        save()
        reload()
        if wasDefault, let oldest = accounts.first {
            setDefaultSender(oldest)
        }
    }

    /// Removes the account along with its SMTP/IMAP Keychain entries. Prefer this over
    /// `delete(_:)` directly so credentials don't linger in the Keychain.
    func deleteWithCredentials(_ target: MailAccount) async {
        let id = target.id
        async let smtp: Void = KeychainService.deleteSMTPPassword(for: id)
        async let imap: Void = KeychainService.deleteIMAPPassword(for: id)
        _ = await (smtp, imap)
        delete(target)
    }

    func reload() {
        accounts = Self.fetch(in: context)
    }

    private func save() {
        guard context.hasChanges else { return }
        do {
            try context.save()
        } catch {
            assertionFailure("MailAccountStore save failed: \(error)")
        }
    }

    private static func fetch(in context: ModelContext) -> [MailAccount] {
        let descriptor = FetchDescriptor<MailAccount>(
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )
        let rows = (try? context.fetch(descriptor)) ?? []
        return coalesce(rows, in: context)
    }

    /// Collapses duplicate rows produced by CloudKit syncing the same single-account install
    /// across devices. Two rows are duplicates when their `smtpUsername` matches
    /// case-insensitively. The oldest wins; the rest are deleted. Empty-username rows
    /// (typically left over from an aborted Add flow) are dropped whenever any non-empty row
    /// exists. Idempotent: a clean store passes through unchanged.
    private static func coalesce(_ rows: [MailAccount], in context: ModelContext) -> [MailAccount] {
        var winners: [MailAccount] = []
        var winnersByKey: [String: MailAccount] = [:]
        var toDelete: [MailAccount] = []

        let hasAnyNonEmpty = rows.contains { !$0.smtpUsername.trimmingCharacters(in: .whitespaces).isEmpty }

        for row in rows {
            let trimmed = row.smtpUsername.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                if hasAnyNonEmpty {
                    toDelete.append(row)
                } else {
                    winners.append(row)
                }
                continue
            }
            let key = trimmed.lowercased()
            if winnersByKey[key] == nil {
                winnersByKey[key] = row
                winners.append(row)
            } else {
                toDelete.append(row)
            }
        }

        guard !toDelete.isEmpty else { return winners }

        // Preserve the default-sender flag if it was on a loser row.
        let needsDefaultReassignment = toDelete.contains(where: { $0.isDefaultSender })
        for row in toDelete { context.delete(row) }
        if needsDefaultReassignment,
           !winners.contains(where: { $0.isDefaultSender }),
           let oldest = winners.first {
            oldest.isDefaultSender = true
        }
        try? context.save()
        return winners
    }
}

