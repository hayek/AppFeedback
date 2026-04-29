import Foundation

enum IMAPClientError: Error, Equatable {
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
}
