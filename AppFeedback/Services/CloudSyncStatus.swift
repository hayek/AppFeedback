import Foundation
import CloudKit
import Observation

enum SyncState: Equatable {
    case unknown
    case syncing
    case unavailable(reason: UnavailableReason)
    case error(message: String)
}

enum UnavailableReason: Equatable {
    case notSignedIn
    case restricted
    case temporarilyUnavailable
}

@MainActor
protocol CloudSyncStatusProviding: AnyObject {
    var state: SyncState { get }
}

@Observable @MainActor
final class CloudSyncStatus: CloudSyncStatusProviding {
    private(set) var state: SyncState = .unknown

    private let container: CKContainer
    nonisolated(unsafe) private var observer: NSObjectProtocol?

    init(container: CKContainer = .default()) {
        self.container = container
        observer = NotificationCenter.default.addObserver(
            forName: .CKAccountChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        Task { await refresh() }
    }

    deinit {
        if let obs = observer { NotificationCenter.default.removeObserver(obs) }
    }

    func refresh() async {
        do {
            let status = try await container.accountStatus()
            switch status {
            case .available:           state = .syncing
            case .noAccount:           state = .unavailable(reason: .notSignedIn)
            case .restricted:          state = .unavailable(reason: .restricted)
            case .couldNotDetermine, .temporarilyUnavailable:
                state = .unavailable(reason: .temporarilyUnavailable)
            @unknown default:          state = .unavailable(reason: .temporarilyUnavailable)
            }
        } catch {
            state = .error(message: error.localizedDescription)
        }
    }
}
