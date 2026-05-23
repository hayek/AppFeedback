import Foundation
import SwiftData
import Observation

/// Per-account read/write access to `MailAccountLocalState` rows. Every method is keyed by
/// `accountID` because UID space is per-IMAP-mailbox: caching a single "current" row would
/// let one account's MailSyncCoordinator stomp on another's `inboxLastUID` between an
/// `ensure` and a later `update`.
@MainActor
@Observable
final class MailAccountLocalStateStore {
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    /// Returns the existing `MailAccountLocalState` row for `accountID`, or inserts a new one.
    @discardableResult
    func ensure(accountID: UUID) -> MailAccountLocalState {
        if let existing = state(accountID: accountID) { return existing }
        let new = MailAccountLocalState(accountID: accountID)
        context.insert(new)
        do {
            try context.save()
        } catch {
            assertionFailure("MailAccountLocalStateStore save failed: \(error)")
        }
        return new
    }

    /// Returns the row for `accountID` without inserting.
    func state(accountID: UUID) -> MailAccountLocalState? {
        var descriptor = FetchDescriptor<MailAccountLocalState>(
            predicate: #Predicate { $0.accountID == accountID }
        )
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    /// Wipes all rows. Used by Settings → Reset.
    func deleteAll() {
        let rows = (try? context.fetch(FetchDescriptor<MailAccountLocalState>())) ?? []
        for r in rows { context.delete(r) }
        try? context.save()
    }

    /// Mutates the row for `accountID` and saves. No-op if no row exists.
    func update(accountID: UUID, _ mutate: (MailAccountLocalState) -> Void) {
        guard let row = state(accountID: accountID) else { return }
        mutate(row)
        do {
            try context.save()
        } catch {
            assertionFailure("MailAccountLocalStateStore save failed: \(error)")
        }
    }
}
