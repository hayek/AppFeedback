import Foundation
import Security

enum KeychainService {
    private static let service = "com.feedbackviewer.tokens"

    static func save(token: String, for repo: RepoConfig) {
        let account = accountKey(for: repo)
        let data = Data(token.utf8)

        let query: [String: Any] = [
            kSecClass as String:            kSecClassGenericPassword,
            kSecAttrService as String:      service,
            kSecAttrAccount as String:      account,
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

    static func load(for repo: RepoConfig) -> String? {
        let query: [String: Any] = [
            kSecClass as String:            kSecClassGenericPassword,
            kSecAttrService as String:      service,
            kSecAttrAccount as String:      accountKey(for: repo),
            kSecAttrSynchronizable as String: kCFBooleanTrue!,
            kSecReturnData as String:       true,
            kSecMatchLimit as String:       kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(for repo: RepoConfig) {
        let query: [String: Any] = [
            kSecClass as String:            kSecClassGenericPassword,
            kSecAttrService as String:      service,
            kSecAttrAccount as String:      accountKey(for: repo),
            kSecAttrSynchronizable as String: kCFBooleanTrue!,
        ]
        SecItemDelete(query as CFDictionary)
    }

    private static func accountKey(for repo: RepoConfig) -> String {
        "\(repo.owner)/\(repo.repo)"
    }
}
