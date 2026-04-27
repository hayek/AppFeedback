import Foundation
import Observation

struct ActivityLogEntry: Identifiable, Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable, CaseIterable {
        case fetchIssues
        case sendEmail
        case testConnection
    }

    enum Status: String, Codable, Sendable {
        case inProgress
        case success
        case failure
    }

    let id: UUID
    let timestamp: Date
    let kind: Kind
    var title: String
    var status: Status
    var detail: String?
}

@MainActor
@Observable
final class ActivityLog {
    /// Newest first.
    private(set) var entries: [ActivityLogEntry] = []

    private let cap: Int
    private let persistenceURL: URL?

    init(persistenceURL: URL?, cap: Int = 500) {
        self.persistenceURL = persistenceURL
        self.cap = cap
    }

    @discardableResult
    func start(kind: ActivityLogEntry.Kind, title: String) -> UUID {
        let entry = ActivityLogEntry(
            id: UUID(),
            timestamp: Date(),
            kind: kind,
            title: title,
            status: .inProgress,
            detail: nil
        )
        entries.insert(entry, at: 0)
        if entries.count > cap {
            entries.removeLast(entries.count - cap)
        }
        return entry.id
    }

    func finish(_ id: UUID, status: ActivityLogEntry.Status, detail: String?) {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[idx].status = status
        entries[idx].detail = detail
    }

    func clearAll() {
        entries.removeAll()
    }
}
