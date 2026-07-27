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

    /// Where a request lands once this process has claimed it. The pid keeps two instances
    /// from picking the same destination, so the claim itself decides the winner.
    static func claimURL(id: UUID, in directory: URL, pid: Int32 = getpid()) -> URL {
        directory.appending(path: "req-\(id.uuidString).claim-\(pid).json")
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
    ///
    /// The claim is an atomic `rename(2)`, not read-then-delete: the installed app and an
    /// Xcode dev build both register this notification name and both wake on the same ping,
    /// so with a plain read each could load the payload before either delete landed and a
    /// single `respond` would email the reporter twice. Exactly one rename can succeed; the
    /// loser sees ENOENT and treats the request as already consumed. `rename` preserves the
    /// modification date, so a claimed file a crash left behind is still reaped by `sweep`.
    static func readRequest(id: UUID, in directory: URL) throws -> CLIRequest {
        let claimed = claimURL(id: id, in: directory)
        guard rename(requestURL(id: id, in: directory).path, claimed.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { try? FileManager.default.removeItem(at: claimed) }
        return try JSONDecoder().decode(CLIRequest.self, from: try Data(contentsOf: claimed))
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

    /// Drops abandoned files (a CLI killed mid-wait, a request no app answered, or a request
    /// claimed by an instance that died before it could reply). Everything in the directory is
    /// judged by modification date, so claimed files need no special case.
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
