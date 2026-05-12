import Foundation
import Security

// Static `async` methods on a non-isolated type run on the cooperative pool
// (SE-0338), so callers on MainActor automatically hop off for the synchronous
// SecItem* calls. No `Task.detached` needed.
enum KeychainService {
    private static let service = "com.feedbackviewer.tokens"

    static func save(token: String, for repo: RepoConfig) async {
        let account = accountKey(for: repo)
        let data = Data(token.utf8)
        let query: [String: Any] = [
            kSecClass as String:              kSecClassGenericPassword,
            kSecAttrService as String:        service,
            kSecAttrAccount as String:        account,
            kSecAttrSynchronizable as String: kCFBooleanTrue!,
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var newItem = query
            newItem[kSecValueData as String] = data
            SecItemAdd(newItem as CFDictionary, nil)
        }
    }

    static func load(for repo: RepoConfig) async -> String? {
        let query: [String: Any] = [
            kSecClass as String:              kSecClassGenericPassword,
            kSecAttrService as String:        service,
            kSecAttrAccount as String:        accountKey(for: repo),
            kSecAttrSynchronizable as String: kCFBooleanTrue!,
            kSecReturnData as String:         true,
            kSecMatchLimit as String:         kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(for repo: RepoConfig) async {
        let query: [String: Any] = [
            kSecClass as String:              kSecClassGenericPassword,
            kSecAttrService as String:        service,
            kSecAttrAccount as String:        accountKey(for: repo),
            kSecAttrSynchronizable as String: kCFBooleanTrue!,
        ]
        SecItemDelete(query as CFDictionary)
    }

    private static func accountKey(for repo: RepoConfig) -> String {
        "\(repo.owner)/\(repo.repo)"
    }

    private static let smtpAccount = "smtp.password"

    static func loadSMTPPassword() async -> String? {
        let query: [String: Any] = [
            kSecClass as String:              kSecClassGenericPassword,
            kSecAttrService as String:        service,
            kSecAttrAccount as String:        smtpAccount,
            kSecAttrSynchronizable as String: kCFBooleanTrue!,
            kSecReturnData as String:         true,
            kSecMatchLimit as String:         kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func deleteLegacySMTPPassword() async {
        let query: [String: Any] = [
            kSecClass as String:              kSecClassGenericPassword,
            kSecAttrService as String:        service,
            kSecAttrAccount as String:        smtpAccount,
            kSecAttrSynchronizable as String: kCFBooleanTrue!,
        ]
        SecItemDelete(query as CFDictionary)
    }

    private static let imapAccount = "imap.password"

    static func loadIMAPPassword() async -> String? {
        loadIMAPPasswordResult().password
    }

    /// Returns the password (if any) along with the raw OSStatus so callers can
    /// distinguish `errSecItemNotFound` (truly missing) from transient failures
    /// like `errSecInteractionNotAllowed` after wake-from-sleep.
    static func loadIMAPPasswordResult() -> (password: String?, status: OSStatus) {
        let query: [String: Any] = [
            kSecClass as String:              kSecClassGenericPassword,
            kSecAttrService as String:        service,
            kSecAttrAccount as String:        imapAccount,
            kSecAttrSynchronizable as String: kCFBooleanTrue!,
            kSecReturnData as String:         true,
            kSecMatchLimit as String:         kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return (nil, status)
        }
        return (String(data: data, encoding: .utf8), status)
    }

    static func deleteLegacyIMAPPassword() async {
        let query: [String: Any] = [
            kSecClass as String:              kSecClassGenericPassword,
            kSecAttrService as String:        service,
            kSecAttrAccount as String:        imapAccount,
            kSecAttrSynchronizable as String: kCFBooleanTrue!,
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Per-account methods

    private static func smtpAccountKey(for accountID: UUID) -> String {
        "smtp.password.\(accountID.uuidString)"
    }

    private static func imapAccountKey(for accountID: UUID) -> String {
        "imap.password.\(accountID.uuidString)"
    }

    @discardableResult
    static func saveSMTPPassword(_ password: String, for accountID: UUID) async -> Bool {
        await saveSynchronizablePassword(password, account: smtpAccountKey(for: accountID))
    }

    static func loadSMTPPassword(for accountID: UUID) async -> String? {
        await loadSynchronizablePassword(account: smtpAccountKey(for: accountID))
    }

    static func deleteSMTPPassword(for accountID: UUID) async {
        await deleteSynchronizablePassword(account: smtpAccountKey(for: accountID))
    }

    @discardableResult
    static func saveIMAPPassword(_ password: String, for accountID: UUID) async -> Bool {
        await saveSynchronizablePassword(password, account: imapAccountKey(for: accountID))
    }

    static func loadIMAPPassword(for accountID: UUID) async -> String? {
        loadIMAPPasswordResult(for: accountID).password
    }

    /// Mirrors `loadIMAPPasswordResult()` so callers can distinguish "missing"
    /// from transient OSStatus failures, per the existing single-account path.
    static func loadIMAPPasswordResult(for accountID: UUID) -> (password: String?, status: OSStatus) {
        let query: [String: Any] = [
            kSecClass as String:              kSecClassGenericPassword,
            kSecAttrService as String:        service,
            kSecAttrAccount as String:        imapAccountKey(for: accountID),
            kSecAttrSynchronizable as String: kCFBooleanTrue!,
            kSecReturnData as String:         true,
            kSecMatchLimit as String:         kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return (nil, status)
        }
        return (String(data: data, encoding: .utf8), status)
    }

    static func deleteIMAPPassword(for accountID: UUID) async {
        await deleteSynchronizablePassword(account: imapAccountKey(for: accountID))
    }

    // MARK: - Shared helpers

    private static func saveSynchronizablePassword(_ password: String, account: String) async -> Bool {
        let data = Data(password.utf8)
        let query: [String: Any] = [
            kSecClass as String:              kSecClassGenericPassword,
            kSecAttrService as String:        service,
            kSecAttrAccount as String:        account,
            kSecAttrSynchronizable as String: kCFBooleanTrue!,
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var newItem = query
            newItem[kSecValueData as String] = data
            return SecItemAdd(newItem as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }

    private static func loadSynchronizablePassword(account: String) async -> String? {
        let query: [String: Any] = [
            kSecClass as String:              kSecClassGenericPassword,
            kSecAttrService as String:        service,
            kSecAttrAccount as String:        account,
            kSecAttrSynchronizable as String: kCFBooleanTrue!,
            kSecReturnData as String:         true,
            kSecMatchLimit as String:         kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func deleteSynchronizablePassword(account: String) async {
        let query: [String: Any] = [
            kSecClass as String:              kSecClassGenericPassword,
            kSecAttrService as String:        service,
            kSecAttrAccount as String:        account,
            kSecAttrSynchronizable as String: kCFBooleanTrue!,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
