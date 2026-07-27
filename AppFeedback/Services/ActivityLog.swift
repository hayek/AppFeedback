import Foundation
import Observation

struct ActivityLogEntry: Identifiable, Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable, CaseIterable {
        case fetchIssues
        case sendEmail
        case testConnection
        case fetchMail
        case downloadAttachment
        case postComment
        case createIssue
        case appStoreAPI
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
    private(set) var entries: [ActivityLogEntry] = []

    private let cap: Int
    private let persistenceURL: URL?
    private var pendingFlush: Task<Void, Never>?

    init(persistenceURL: URL?, cap: Int = 500) {
        self.persistenceURL = persistenceURL
        self.cap = cap
        load()
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
        scheduleFlush()
        return entry.id
    }

    func finish(_ id: UUID, status: ActivityLogEntry.Status, detail: String?) {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[idx].status = status
        entries[idx].detail = detail
        scheduleFlush()
    }

    func clearAll() {
        entries.removeAll()
        scheduleFlush()
    }

    // MARK: - Persistence

    private func load() {
        guard let url = persistenceURL,
              let data = try? Data(contentsOf: url),
              let decoded = try? Self.decoder.decode([ActivityLogEntry].self, from: data) else {
            return
        }
        entries = decoded
    }

    private func scheduleFlush() {
        guard let url = persistenceURL else { return }
        pendingFlush?.cancel()
        let snapshot = entries
        pendingFlush = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            await ActivityLog.write(snapshot, to: url)
        }
    }

    nonisolated private static func write(_ entries: [ActivityLogEntry], to url: URL) async {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard let data = try? encoder.encode(entries) else { return }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - Test hooks

    func flushForTesting() async throws {
        guard let url = persistenceURL else { return }
        pendingFlush?.cancel()
        pendingFlush = nil
        await Self.write(entries, to: url)
    }

    func loadForTesting() async throws {
        load()
    }

    // MARK: - JSON coders

    nonisolated private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    nonisolated private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
