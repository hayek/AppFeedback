#if os(macOS)
import Foundation

/// File-backed request/response passing. Distributed-notification userInfo is plist/XPC
/// bounded and cannot carry an email body, so only the correlation UUID travels in the
/// notification and the payload lands on disk.
enum CLIIPCTransport {

    static var directory: URL {
        URL.applicationSupportDirectory
            .appending(path: "AppFeedback", directoryHint: .isDirectory)
            .appending(path: "cli-ipc", directoryHint: .isDirectory)
    }

    static func requestURL(id: UUID, in directory: URL) -> URL {
        directory.appending(path: "req-\(id.uuidString).json")
    }

    static func responseURL(id: UUID, in directory: URL) -> URL {
        directory.appending(path: "res-\(id.uuidString).json")
    }

    static func ensureDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    static func write(request: CLIRequest, in directory: URL) throws {
        try ensureDirectory(directory)
        try JSONEncoder().encode(request)
            .write(to: requestURL(id: request.id, in: directory), options: .atomic)
    }

    /// Reading consumes the file — a request is answered once.
    static func readRequest(id: UUID, in directory: URL) throws -> CLIRequest {
        let url = requestURL(id: id, in: directory)
        let data = try Data(contentsOf: url)
        try? FileManager.default.removeItem(at: url)
        return try JSONDecoder().decode(CLIRequest.self, from: data)
    }

    static func write(response: CLIResponse, in directory: URL) throws {
        try ensureDirectory(directory)
        try JSONEncoder().encode(response)
            .write(to: responseURL(id: response.id, in: directory), options: .atomic)
    }

    static func readResponse(id: UUID, in directory: URL) throws -> CLIResponse {
        let url = responseURL(id: id, in: directory)
        let data = try Data(contentsOf: url)
        try? FileManager.default.removeItem(at: url)
        return try JSONDecoder().decode(CLIResponse.self, from: data)
    }

    /// Drops abandoned files (a CLI killed mid-wait, or a request no app answered).
    static func sweep(in directory: URL = directory, olderThan seconds: TimeInterval = 3600) {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-seconds)
        for entry in entries {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            if let modified, modified < cutoff { try? manager.removeItem(at: entry) }
        }
    }
}
#endif
