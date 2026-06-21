import Foundation
import Observation

/// What Phase 4's "Respond on App Store" panel needs to act on a review: the authenticated client,
/// whether the key is read-only (a 403 on a prior write flips this), the GitHub sink coordinates
/// for the "responded" record comment, and a callback to propagate a newly-discovered 403 back to
/// the coordinator so subsequent controllers on the same product are seeded read-only.
/// Defined here (Phase 3 owns it); Phase 4 only consumes it.
struct AppStoreResponderContext: Sendable {
    let client: any AppStoreConnectClientProtocol
    let isReadOnly: Bool
    let owner: String
    let repo: String
    /// Called on the MainActor when a live 403 is observed by a response controller. Propagates
    /// the read-only flag to the coordinator so later-built controllers inherit it. `nil` in
    /// contexts where no coordinator is available (e.g. tests).
    let onReadOnly: (@Sendable @MainActor () -> Void)?
}

/// Owns one `AppStoreReviewCoordinator` per product that has App Store Connect configured.
/// Lifecycle is synced to the product list via `syncWithProducts(_:)` (idempotent). Mirrors
/// `MailSyncCoordinatorRegistry`'s grain: spin-up starts the poll loop, tear-down stops it.
@MainActor
@Observable
final class AppStoreReviewCoordinatorRegistry {
    typealias CoordinatorFactory = (ASCProductConfig) -> AppStoreReviewCoordinator

    private let factory: CoordinatorFactory
    private var coordinators: [UUID: AppStoreReviewCoordinator] = [:]
    /// Tracks products whose key is known read-only, mirrored here synchronously on the MainActor
    /// so `responderContext(productID:)` can short-circuit without an async hop to the coordinator.
    /// This closes the race window where a concurrent `responderContext` call could read
    /// `isReadOnly: false` before the fire-and-forget Task in `markReadOnly` has executed.
    private var readOnlyProductIDs: Set<UUID> = []

    init(factory: @escaping CoordinatorFactory) { self.factory = factory }

    var coordinatorCount: Int { coordinators.count }
    func coordinator(for id: UUID) -> AppStoreReviewCoordinator? { coordinators[id] }

    /// [responderContext] The seam Phase 4 consumes. Reads the live coordinator's client + read-only
    /// flag + sink coordinates. `async` because the coordinator is an actor. nil when the product has
    /// no live coordinator (ASC not configured). The returned context embeds an `onReadOnly` callback
    /// that, when invoked by a response controller after a live 403, calls `markReadOnly(productID:)`
    /// so subsequent controllers on the same product are seeded read-only.
    func responderContext(productID: UUID) async -> AppStoreResponderContext? {
        guard let coord = coordinators[productID] else { return nil }
        // Short-circuit: if this product is already known read-only on the registry (set
        // synchronously in markReadOnly before the async coordinator hop), skip the actor
        // call for the flag. This closes the race window where a concurrent call could
        // still see isReadOnly: false before the detached Task has run on the coordinator.
        let isReadOnly: Bool
        if readOnlyProductIDs.contains(productID) {
            isReadOnly = true
        } else {
            isReadOnly = await coord.readOnly()
        }
        return AppStoreResponderContext(
            client: await coord.responderClient,
            isReadOnly: isReadOnly,
            owner: await coord.sinkOwner,
            repo: await coord.sinkRepo,
            onReadOnly: { [weak self] in self?.markReadOnly(productID: productID) })
    }

    /// Called by a response controller when a live 403 is received. Forwards to the
    /// coordinator so `responderContext(productID:)` returns `isReadOnly: true` for any
    /// subsequently-built controller on the same product.
    func markReadOnly(productID: UUID) {
        // Record immediately on the MainActor before any async hop so that a concurrent
        // `responderContext(productID:)` call observes the read-only state right away,
        // eliminating the race window that existed when only the coordinator actor held this flag.
        readOnlyProductIDs.insert(productID)
        guard let coord = coordinators[productID] else { return }
        Task { await coord.markReadOnly() }
    }

    /// [F] Per-source status for the App Store settings form. nil when no live coordinator.
    func status(productID: UUID) async -> (lastSuccessAt: Date?, lastError: String?)? {
        guard let coord = coordinators[productID] else { return nil }
        return await coord.status()
    }

    /// Reconciles the live coordinator set with the products that have ASC configured. Idempotent.
    func syncWithProducts(_ configs: [ASCProductConfig]) {
        let currentIDs = Set(configs.map(\.id))
        for (id, coord) in coordinators where !currentIDs.contains(id) {
            Task { await coord.stop() }
            coordinators[id] = nil
            readOnlyProductIDs.remove(id)
        }
        for cfg in configs where coordinators[cfg.id] == nil {
            let coord = factory(cfg)
            coordinators[cfg.id] = coord
            Task { await coord.start() }
        }
    }

    func start() { for coord in coordinators.values { Task { await coord.start() } } }

    func pollNow() async {
        await withTaskGroup(of: Void.self) { group in
            for coord in coordinators.values { group.addTask { await coord.pollNow() } }
        }
    }

    func stop() { for coord in coordinators.values { Task { await coord.stop() } } }

    /// Stops and restarts a single product's coordinator (used when its ASC credentials change).
    /// Clears the read-only flag on the registry so the new coordinator starts writable.
    func restart(productID: UUID, configs: [ASCProductConfig]) {
        if let coord = coordinators[productID] {
            Task { await coord.stop() }
            coordinators[productID] = nil
        }
        readOnlyProductIDs.remove(productID)
        syncWithProducts(configs)
    }
}
