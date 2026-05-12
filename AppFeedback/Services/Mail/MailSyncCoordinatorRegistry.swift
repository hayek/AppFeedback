import Foundation
import Observation

/// Owns one `MailSyncCoordinator` per configured `MailAccount`.
///
/// Call `syncWithAccounts()` on launch and whenever the account list changes (add/remove).
/// `pollNow()` fans out to every live coordinator. Each spin-up automatically starts the
/// coordinator's poll loop; each tear-down stops it.
@MainActor
@Observable
final class MailSyncCoordinatorRegistry {
    typealias CoordinatorFactory = (UUID) -> MailSyncCoordinator

    private let accountStore: MailAccountStore
    private let factory: CoordinatorFactory
    private var coordinators: [UUID: MailSyncCoordinator] = [:]

    init(accountStore: MailAccountStore, factory: @escaping CoordinatorFactory) {
        self.accountStore = accountStore
        self.factory = factory
    }

    var coordinatorCount: Int { coordinators.count }

    func coordinator(for id: UUID) -> MailSyncCoordinator? { coordinators[id] }

    /// Reconciles the live coordinator set with the current account list. Idempotent.
    func syncWithAccounts() {
        let currentIDs = Set(accountStore.accounts.map(\.id))

        // Tear down removed accounts.
        for (id, coord) in coordinators where !currentIDs.contains(id) {
            Task { await coord.stop() }
            coordinators[id] = nil
        }

        // Spin up new accounts.
        for acc in accountStore.accounts where coordinators[acc.id] == nil {
            let coord = factory(acc.id)
            coordinators[acc.id] = coord
            Task { await coord.start() }
        }
    }

    /// Starts every live coordinator's poll loop. Safe to call multiple times.
    func start() {
        for coord in coordinators.values {
            Task { await coord.start() }
        }
    }

    /// Fans out a manual poll to every live coordinator.
    func pollNow() async {
        await withTaskGroup(of: Void.self) { group in
            for coord in coordinators.values {
                group.addTask { await coord.pollNow() }
            }
        }
    }

    /// Stops every live coordinator. Safe to call multiple times.
    func stop() {
        for coord in coordinators.values {
            Task { await coord.stop() }
        }
    }

    /// Stops and restarts a single account's coordinator (used when credentials change).
    func restart(accountID: UUID) {
        guard let coord = coordinators[accountID] else {
            syncWithAccounts()
            return
        }
        Task {
            await coord.stop()
            await coord.start()
        }
    }
}
