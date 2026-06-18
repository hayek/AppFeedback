import Foundation
import SwiftData

/// One-time, idempotent copy of every legacy `Repo` row into a `Product` with the SAME
/// `id`/`owner`/`repo` and all fields. Run in `AppFeedbackApp.init()` when not testing,
/// exactly like `MailAccountMigration`. Gated by a `UserDefaults` flag set only on success,
/// so a failure leaves legacy `Repo` data intact and retries next launch.
enum ProductMigration {
    static let completedKey = "product.migration.v1.completed"

    @MainActor
    static func run(context: ModelContext, defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: completedKey) else { return }

        let legacyRepos: [Repo]
        do {
            legacyRepos = try context.fetch(FetchDescriptor<Repo>())
        } catch {
            // Leave the flag unset so we retry next launch.
            return
        }
        if legacyRepos.isEmpty {
            // Nothing to migrate (fresh install or already migrated + rows retired).
            defaults.set(true, forKey: completedKey)
            return
        }

        // Index existing Products by id to skip any already-copied rows defensively.
        let existing = (try? context.fetch(FetchDescriptor<Product>())) ?? []
        var existingIDs = Set(existing.map(\.id))

        for legacy in legacyRepos {
            if existingIDs.contains(legacy.id) {
                // Already has a Product; retire the legacy row and move on.
                context.delete(legacy)
                continue
            }
            let product = Product(
                id: legacy.id,
                displayName: legacy.displayName,
                owner: legacy.owner,
                repo: legacy.repo,
                hiddenAppNames: legacy.hiddenAppNames,
                appColors: legacy.appColors,
                colorHex: legacy.colorHex,
                createdAt: legacy.createdAt,
                mirrorEmailsToGitHub: legacy.mirrorEmailsToGitHub,
                redactEmailAddresses: legacy.redactEmailAddresses,
                connectedRepoOwner: legacy.connectedRepoOwner,
                connectedRepoName: legacy.connectedRepoName
                // appStore*/feedbackInboxAccountID default nil — config only, no legacy source.
            )
            context.insert(product)
            existingIDs.insert(product.id)
            context.delete(legacy)
        }

        do {
            try context.save()
            defaults.set(true, forKey: completedKey)   // flag ONLY on success
        } catch {
            // Save failed: leave the flag unset so the migration retries next launch.
        }
    }
}
