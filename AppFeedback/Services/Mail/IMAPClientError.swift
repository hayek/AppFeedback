import Foundation

enum IMAPClientError: LocalizedError, Equatable {
    /// Reserved for future use — e.g. a persistent-connection path that detects a dropped session.
    case notConnected

    /// Authentication was rejected by the server.
    case authFailed

    /// A message or server response could not be decoded.
    case malformed(detail: String)

    /// Thrown by IMAPClientProvider when MailAccount has IMAP host configured but Keychain has no password.
    case passwordUnavailable

    /// The operation was cancelled by the caller.
    case cancelled

    /// A transport-level failure. The underlying error is stringified so the
    /// enum stays `Equatable` without requiring `AnyError` wrappers.
    case transport(underlying: String)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Not connected to the IMAP server."
        case .authFailed:
            return "IMAP login was rejected. Most providers require an app-specific password (not your account password) — open the account in Email settings to generate one."
        case .malformed(let detail):
            return "Malformed IMAP response: \(detail)"
        case .passwordUnavailable:
            return "No IMAP password is stored. Open Email settings and enter your app password."
        case .cancelled:
            return "The IMAP operation was cancelled."
        case .transport(let underlying):
            return "IMAP transport error: \(underlying)"
        }
    }
}
