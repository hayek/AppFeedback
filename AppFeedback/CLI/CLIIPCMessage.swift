#if os(macOS)
import Foundation

enum CLIRequestKind: String, Codable {
    case refresh
    case createTask
    case linkTask
    case unlinkTask
    case respond
}

/// Payload values are strings so the envelope stays trivially Codable across the process
/// boundary; numeric fields are parsed by the responder.
struct CLIRequest: Codable {
    let id: UUID
    let kind: CLIRequestKind
    var payload: [String: String]

    init(id: UUID = UUID(), kind: CLIRequestKind, payload: [String: String]) {
        self.id = id
        self.kind = kind
        self.payload = payload
    }
}

struct CLIResponse: Codable {
    let id: UUID
    let ok: Bool
    var errorCode: String?
    var errorMessage: String?
    var errorHint: String?
    var warnings: [String] = []
    /// The successful result, already JSON-encoded by the app side.
    var json: String?

    init(id: UUID, ok: Bool, errorCode: String? = nil, errorMessage: String? = nil,
         errorHint: String? = nil, warnings: [String] = [], json: String? = nil) {
        self.id = id
        self.ok = ok
        self.errorCode = errorCode
        self.errorMessage = errorMessage
        self.errorHint = errorHint
        self.warnings = warnings
        self.json = json
    }
}
#endif
