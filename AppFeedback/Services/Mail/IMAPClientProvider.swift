#if canImport(SwiftMail)
import Foundation

/// Builds a fresh IMAPClient per call, reading credentials from MailAccount + Keychain.
/// Allows MailSyncCoordinator to receive a live IMAPClientProtocol without holding stale credentials.
actor IMAPClientProvider: IMAPClientProtocol {
    private let accountStore: MailAccountStore  // @MainActor

    init(accountStore: MailAccountStore) {
        self.accountStore = accountStore
    }

    func listInbox(sinceUID: UInt32) async throws -> [ParsedInboundMessage] {
        let client = try await currentClient()
        return try await client.listInbox(sinceUID: sinceUID)
    }

    func listSent(sinceDate: Date) async throws -> [ParsedInboundMessage] {
        let client = try await currentClient()
        return try await client.listSent(sinceDate: sinceDate)
    }

    func fetchAttachmentBytes(uid: UInt32, folder: String, partID: String) async throws -> Data {
        let client = try await currentClient()
        return try await client.fetchAttachmentBytes(uid: uid, folder: folder, partID: partID)
    }

    func testConnection() async throws {
        let client = try await currentClient()
        try await client.testConnection()
    }

    private func currentClient() async throws -> IMAPClient {
        let snap: (host: String, port: Int, username: String)? = await MainActor.run {
            guard let acc = accountStore.account, !acc.imapHost.isEmpty else { return nil }
            return (acc.imapHost, acc.imapPort, acc.imapUsername)
        }
        guard let snap else { throw IMAPClientError.notConnected }
        let password = await KeychainService.loadIMAPPassword() ?? ""
        if password.isEmpty { throw IMAPClientError.passwordUnavailable }
        return IMAPClient(host: snap.host, port: snap.port, username: snap.username, password: password)
    }
}
#endif
