import Foundation
import SwiftData
import Observation

@MainActor
@Observable
final class MailSettingsStore {
    private(set) var settings: MailSettings

    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
        self.settings = Self.fetchOrCreate(in: context)
    }

    func update(_ mutate: (MailSettings) -> Void) {
        mutate(settings)
        if context.hasChanges {
            do {
                try context.save()
            } catch {
                assertionFailure("MailSettingsStore save failed: \(error)")
            }
        }
    }

    func reload() {
        settings = Self.fetchOrCreate(in: context)
    }

    private static func fetchOrCreate(in context: ModelContext) -> MailSettings {
        let descriptor = FetchDescriptor<MailSettings>(
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )
        let rows = (try? context.fetch(descriptor)) ?? []
        if let first = rows.first {
            // Coalesce extras (can happen via CloudKit race on first multi-device sync).
            for extra in rows.dropFirst() {
                context.delete(extra)
            }
            saveIfChanged(context)
            return first
        }
        let fresh = MailSettings()
        context.insert(fresh)
        saveIfChanged(context)
        return fresh
    }

    private static func saveIfChanged(_ context: ModelContext) {
        guard context.hasChanges else { return }
        do {
            try context.save()
        } catch {
            assertionFailure("MailSettingsStore save failed: \(error)")
        }
    }
}
