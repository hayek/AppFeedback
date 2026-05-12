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
        return (try? context.fetch(descriptor)) ?? []
    }
}

