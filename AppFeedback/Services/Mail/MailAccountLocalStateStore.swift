import Foundation
import SwiftData
import Observation

@MainActor
@Observable
final class MailAccountLocalStateStore {
    private(set) var state: MailAccountLocalState?
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    /// Returns the existing `MailAccountLocalState` row for `accountID`, or inserts a new one.
    @discardableResult
    func ensure(accountID: UUID) -> MailAccountLocalState {
        // Try to fetch existing
        var descriptor = FetchDescriptor<MailAccountLocalState>(
            predicate: #Predicate { $0.accountID == accountID }
        )
        descriptor.fetchLimit = 1
        if let existing = (try? context.fetch(descriptor))?.first {
            state = existing
            return existing
        }
        // Insert new
        let new = MailAccountLocalState(accountID: accountID)
        context.insert(new)
        do {
            try context.save()
        } catch {
            assertionFailure("MailAccountLocalStateStore save failed: \(error)")
        }
        state = new
        return new
    }

    /// Mutates the current state (if any) and saves.
    func update(_ mutate: (MailAccountLocalState) -> Void) {
        guard let s = state else { return }
        mutate(s)
        do {
            try context.save()
        } catch {
            assertionFailure("MailAccountLocalStateStore save failed: \(error)")
        }
    }
}
