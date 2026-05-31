import Foundation
import Security

/// Minimal Keychain wrapper for ssh host passwords, so saved servers don't need re-entering each
/// launch. Stored as a generic password keyed by the ssh destination (`user@host`); the value never
/// touches UserDefaults or logs.
enum Keychain {
    private static let service = "com.tfa.ssh"

    private static func baseQuery(account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func savePassword(_ password: String, account: String) {
        SecItemDelete(baseQuery(account: account) as CFDictionary) // upsert
        var add = baseQuery(account: account)
        add[kSecValueData as String] = Data(password.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func readPassword(account: String) -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func deletePassword(account: String) {
        SecItemDelete(baseQuery(account: account) as CFDictionary)
    }
}
