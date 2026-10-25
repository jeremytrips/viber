import Foundation
import Security

/// Jira API tokens, one per site, in the login Keychain.
enum JiraKeychain {
    private static let service = "Viber Jira"

    static func token(for host: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: host, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ token: String, for host: String) {
        remove(for: host)
        let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: host, kSecValueData as String: Data(token.utf8),
                                   kSecAttrLabel as String: "Viber: Jira token for \(host)"]
        SecItemAdd(item as CFDictionary, nil)
    }

    static func remove(for host: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: host]
        SecItemDelete(query as CFDictionary)
    }
}
