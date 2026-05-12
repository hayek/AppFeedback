#if canImport(SwiftMail)
import Foundation

/// Builds a fresh IMAPClient per call, reading credentials from MailAccount + Keychain.
/// Allows MailSyncCoordinator to receive a live IMAPClientProtocol without holding stale credentials.
actor IMAPClientProvider: IMAPClientProtocol {
    private let accountStore: MailAccountStore  // @MainActor
    private let accountID: UUID

    init(accountStore: MailAccountStore, accountID: UUID) {
        self.accountStore = accountStore
        self.accountID = accountID
    }

    func listInbox(sinceUID: UInt32, fromAddresses: [String]) async throws -> [ParsedInboundMessage] {
        let client = try await makeClient()
        return try await client.listInbox(sinceUID: sinceUID, fromAddresses: fromAddresses)
    }

    func listSent(sinceDate: Date) async throws -> [ParsedInboundMessage] {
        let client = try await makeClient()
        return try await client.listSent(sinceDate: sinceDate)
    }

    func fetchAttachmentBytes(uid: UInt32, folder: String, partID: String) async throws -> Data {
        let client = try await makeClient()
        return try await client.fetchAttachmentBytes(uid: uid, folder: folder, partID: partID)
    }

    func testConnection() async throws {
        let client = try await makeClient()
        try await client.testConnection()
    }

    /// Builds a fresh IMAPClient each call, reading credentials from the account store and Keychain.
    private func makeClient() async throws -> IMAPClient {
        let accountID = self.accountID
        let snap: (host: String, port: Int, username: String)? = await MainActor.run {
            guard let acc = accountStore.account(id: accountID),
                  !acc.imapHost.isEmpty,
                  !acc.imapUsername.isEmpty else { return nil }
            return (acc.imapHost, acc.imapPort, acc.imapUsername)
        }
        guard let snap else { throw IMAPClientError.passwordUnavailable }
        let password = try await loadIMAPPasswordWithRetry()
        return IMAPClient(host: snap.host, port: snap.port, username: snap.username, password: password)
    }

    /// Reads the IMAP password from the Keychain, distinguishing a truly missing
    /// item from transient failures (e.g. `errSecInteractionNotAllowed` shortly
    /// after wake-from-sleep, or iCloud Keychain sync hiccups). Retries transient
    /// failures once after a short delay so we don't surface a misleading
    /// "no password stored" error for what is really a transient SecItem read.
    private func loadIMAPPasswordWithRetry() async throws -> String {
        let accountID = self.accountID
        for attempt in 0..<2 {
            let (pw, status) = KeychainService.loadIMAPPasswordResult(for: accountID)
            if status == errSecSuccess, let pw, !pw.isEmpty {
                return pw
            }
            if status == errSecItemNotFound || (status == errSecSuccess && (pw ?? "").isEmpty) {
                throw IMAPClientError.passwordUnavailable
            }
            if attempt == 0 {
                try? await Task.sleep(nanoseconds: 250_000_000)
                continue
            }
            throw IMAPClientError.transport(underlying: "Keychain read failed (OSStatus \(status))")
        }
        throw IMAPClientError.passwordUnavailable
    }
}
#endif
