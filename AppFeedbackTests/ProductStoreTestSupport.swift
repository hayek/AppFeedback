import Foundation
import SwiftData
@testable import AppFeedback

/// Reusable in-memory `ProductStore` for tests. Phases 1–5 build products through this
/// helper rather than hand-rolling a container, so the seed surface stays in one place.
///
/// Example (Phase 5 email source):
/// ```
/// let harness = try ProductStoreTestHarness()
/// let inboxID = UUID()
/// let product = harness.seed(owner: "octo", repo: "feedback",
///                            redactEmailAddresses: true,
///                            feedbackInboxAccountID: inboxID)
/// ```
@MainActor
struct ProductStoreTestHarness {
    let container: ModelContainer
    let context: ModelContext
    let store: ProductStore

    /// `extraModels` lets a caller widen the schema (e.g. Phase 5 adds `MailThread.self`,
    /// `MailAccount.self`) while still getting the standard `Product` + `HiddenApp` registration.
    init(extraModels: [any PersistentModel.Type] = []) throws {
        let schema = Schema([Product.self, HiddenApp.self] + extraModels)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        container = try ModelContainer(for: schema, configurations: config)
        context = ModelContext(container)
        store = ProductStore(context: context, hiddenAppStore: HiddenAppStore(context: context))
    }

    /// Seeds one product and returns its config. Mirrors `ProductConfig`'s field set so a
    /// caller can set any source-config field at construction time.
    @discardableResult
    func seed(
        owner: String,
        repo: String,
        displayName: String = "Test Product",
        redactEmailAddresses: Bool = true,
        feedbackInboxAccountID: UUID? = nil,
        appStoreIssuerID: String? = nil,
        appStoreKeyID: String? = nil,
        appStoreAppAppleID: String? = nil
    ) -> ProductConfig {
        let config = ProductConfig(
            displayName: displayName,
            owner: owner,
            repo: repo,
            redactEmailAddresses: redactEmailAddresses,
            appStoreIssuerID: appStoreIssuerID,
            appStoreKeyID: appStoreKeyID,
            appStoreAppAppleID: appStoreAppAppleID,
            feedbackInboxAccountID: feedbackInboxAccountID
        )
        store.add(config)
        return config
    }
}
