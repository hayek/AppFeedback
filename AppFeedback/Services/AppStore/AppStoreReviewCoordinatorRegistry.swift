import Foundation
import Observation

/// What Phase 4's "Respond on App Store" panel needs to act on a review: the authenticated client,
/// whether the key is read-only (a 403 on a prior write flips this), and the GitHub sink coordinates
/// for the "responded" record comment. Defined here (Phase 3 owns it); Phase 4 only consumes it.
struct AppStoreResponderContext: Sendable {
    let client: any AppStoreConnectClientProtocol
    let isReadOnly: Bool
    let owner: String
    let repo: String
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

    init(factory: @escaping CoordinatorFactory) { self.factory = factory }

    var coordinatorCount: Int { coordinators.count }
    func coordinator(for id: UUID) -> AppStoreReviewCoordinator? { coordinators[id] }

    /// [responderContext] The seam Phase 4 consumes. Reads the live coordinator's client + read-only
    /// flag + sink coordinates. `async` because the coordinator is an actor. nil when the product has
    /// no live coordinator (ASC not configured).
    func responderContext(productID: UUID) async -> AppStoreResponderContext? {
        guard let coord = coordinators[productID] else { return nil }
        return AppStoreResponderContext(
            client: await coord.responderClient,
            isReadOnly: await coord.readOnly(),
            owner: await coord.sinkOwner,
            repo: await coord.sinkRepo)
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
    func restart(productID: UUID, configs: [ASCProductConfig]) {
        if let coord = coordinators[productID] {
            Task { await coord.stop() }
            coordinators[productID] = nil
        }
        syncWithProducts(configs)
    }
}
