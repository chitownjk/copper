import Foundation
import Security

/// API keys live in the Keychain — never UserDefaults, never a plist, never a
/// log line (PRD §5, E2.3 acceptance criteria).
public enum KeychainStore {
    /// Keys are namespaced under the app so a future bundle-ID rename (E3.5)
    /// has one obvious place to migrate.
    public static let service = "com.meetingnotes.apikeys"

    public enum Account: String {
        case anthropic
        case openAI = "openai"
        case localServer = "local"
    }

    public static func set(_ value: String?, for account: Account) {
        guard let value, !value.isEmpty else {
            remove(account)
            return
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: Data(value.utf8),
            // Available after first unlock so a scheduled/background summary
            // still works, but never syncs to iCloud or a backup.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil)
        }
    }

    public static func get(_ account: Account) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty
        else { return nil }
        return value
    }

    public static func has(_ account: Account) -> Bool {
        get(account) != nil
    }

    public static func remove(_ account: Account) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue
        ]
        SecItemDelete(query as CFDictionary)
    }
}
