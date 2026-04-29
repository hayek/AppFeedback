import Foundation
import SwiftData
import Observation

@MainActor
@Observable
final class MailAccountStore {
    private(set) var account: MailAccount?

    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
        self.account = Self.fetch(in: context)
    }

    func upsert(_ mutate: (MailAccount) -> Void) {
        let target: MailAccount
        if let existing = account {
            target = existing
        } else {
            let new = MailAccount()
            context.insert(new)
            target = new
        }
        mutate(target)
        // Skip the save (and the CloudKit round-trip) when nothing actually changed —
        // settings views debounce-save on every keystroke, even when the user types and
        // immediately backspaces. SwiftData's own dirty tracking handles the diff.
        if context.hasChanges {
            do {
                try context.save()
            } catch {
                assertionFailure("MailAccountStore save failed: \(error)")
            }
        }
        account = target
    }

    func deleteAccount() {
        guard let acc = account else { return }
        context.delete(acc)
        try? context.save()
        account = nil
    }

    func reload() {
        account = Self.fetch(in: context)
    }

    private static func fetch(in context: ModelContext) -> MailAccount? {
        var descriptor = FetchDescriptor<MailAccount>(
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }
}
