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
    private(set) var hasBootstrapped: Bool = false

    private let container: CKContainer?
    private var observerTask: Task<Void, Never>?

    init(container: CKContainer? = nil) {
        self.container = container ?? Self.defaultContainerForCurrentEnvironment()
        observerTask = Task { @MainActor [weak self] in
            // Subscribe before the initial refresh so we don't miss a CKAccountChanged
            // posted during the bootstrap window.
            let stream = NotificationCenter.default.notifications(named: .CKAccountChanged)
            await self?.refresh()
            self?.hasBootstrapped = true
            for await _ in stream {
                await self?.refresh()
            }
        }
    }

    isolated deinit {
        observerTask?.cancel()
    }

    private static func defaultContainerForCurrentEnvironment() -> CKContainer? {
        // CKContainer.default() crashes when the host process lacks CloudKit
        // entitlements (e.g. an unsigned unit-test bundle). Skip it in that case.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else {
            return nil
        }
        return .default()
    }

    func refresh() async {
        guard let container else {
            state = .unavailable(reason: .temporarilyUnavailable)
            hasBootstrapped = true
            return
        }
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
