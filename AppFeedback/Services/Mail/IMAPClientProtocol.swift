import Foundation

/// Protocol so Task 5's MailSyncCoordinator can swap in a mock.
/// Declared outside the SwiftMail `#if` guard so test targets that do not
/// import SwiftMail can still conform to it (e.g. MockIMAPClient in Task 5).
protocol IMAPClientProtocol: Sendable {
    /// Returns messages from INBOX whose UID is strictly greater than `sinceUID`
    /// AND whose sender matches one of `fromAddresses`. Filtering by FROM keeps the
    /// fetch tiny on busy mailboxes — Gmail indexes From efficiently and we already
    /// know who we wrote to. Pass an empty array to short-circuit (no recipients to
    /// expect replies from yet).
    func listInbox(sinceUID: UInt32, fromAddresses: [String]) async throws -> [ParsedInboundMessage]

    /// Returns messages from the Sent folder with an internal date on or after `sinceDate`.
    func listSent(sinceDate: Date) async throws -> [ParsedInboundMessage]

    /// Lazily fetches raw bytes for a single attachment part.
    func fetchAttachmentBytes(uid: UInt32, folder: String, partID: String) async throws -> Data

    /// Opens, authenticates, and immediately disconnects — useful for the "Test Connection" button.
    func testConnection() async throws
}
