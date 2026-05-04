import Foundation
import Observation

/// Persists SMTP failure reasons keyed by messageID. Local-only by design: failures are
/// usually transient (network, password) and the retry has to happen on the device whose
/// keychain holds the SMTP password, so syncing failure strings to other devices is
/// noise. Cleared when a subsequent send for the same messageID succeeds.
@MainActor
@Observable
final class OutboundFailureStore {
    private(set) var failures: [String: String] = [:]
    private let persistenceURL: URL?

    init(persistenceURL: URL?) {
        self.persistenceURL = persistenceURL
        load()
    }

    func reason(for messageID: String) -> String? {
        failures[messageID]
    }

    func record(_ messageID: String, reason: String) {
        failures[messageID] = reason
        save()
    }

    func clear(_ messageID: String) {
        guard failures.removeValue(forKey: messageID) != nil else { return }
        save()
    }

    private func load() {
        guard let url = persistenceURL,
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: String].self, from: data) else {
            return
        }
        failures = decoded
    }

    private func save() {
        guard let url = persistenceURL else { return }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(failures)
            try data.write(to: url, options: .atomic)
        } catch {
            assertionFailure("OutboundFailureStore save failed: \(error)")
        }
    }
}
