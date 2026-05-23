import Foundation

/// Result of an inbox poll: the parsed messages plus the mailbox's current `UIDVALIDITY`.
/// Callers persist `uidValidity` alongside `inboxLastUID`; a change means UID space was
/// reassigned (mailbox recreated, restored from backup) and `inboxLastUID` must be reset.
struct InboxPollResult: Sendable {
    let messages: [ParsedInboundMessage]
    let uidValidity: UInt32
}

/// Protocol so Task 5's MailSyncCoordinator can swap in a mock.
/// Declared outside the SwiftMail `#if` guard so test targets that do not
/// import SwiftMail can still conform to it (e.g. MockIMAPClient in Task 5).
protocol IMAPClientProtocol: Sendable {
    /// Returns messages from INBOX whose UID is strictly greater than `sinceUID`
    /// AND whose sender matches one of `fromAddresses`. Filtering by FROM keeps the
    /// fetch tiny on busy mailboxes — Gmail indexes From efficiently and we already
    /// know who we wrote to. Pass an empty array to short-circuit (no recipients to
    /// expect replies from yet).
    ///
    /// `expectedUIDValidity` is the value previously persisted for this mailbox. If it
    /// is non-zero and the server reports a different value, the implementation treats
    /// `sinceUID` as stale and fetches as if from zero. The returned `uidValidity` is
    /// always the server's current value; the caller persists it before the next poll.
    func listInbox(sinceUID: UInt32, expectedUIDValidity: UInt32, fromAddresses: [String]) async throws -> InboxPollResult

    /// Returns messages from the Sent folder with an internal date on or after `sinceDate`.
    func listSent(sinceDate: Date) async throws -> [ParsedInboundMessage]

    /// Lazily fetches raw bytes for a single attachment part.
    func fetchAttachmentBytes(uid: UInt32, folder: String, partID: String) async throws -> Data

    /// Opens, authenticates, and immediately disconnects — useful for the "Test Connection" button.
    func testConnection() async throws
}
