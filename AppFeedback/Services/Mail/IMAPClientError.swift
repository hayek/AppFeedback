import Foundation

enum IMAPClientError: Error, Equatable {
    /// The IMAP session is not connected.
    case notConnected

    /// Authentication was rejected by the server.
    case authFailed

    /// A message or server response could not be decoded.
    case malformed(detail: String)

    /// A stored credential could not be retrieved.
    case passwordUnavailable

    /// The operation was cancelled by the caller.
    case cancelled

    /// A transport-level failure. The underlying error is stringified so the
    /// enum stays `Equatable` without requiring `AnyError` wrappers.
    case transport(underlying: String)
}
