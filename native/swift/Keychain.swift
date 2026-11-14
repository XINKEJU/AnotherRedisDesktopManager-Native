import Foundation
import Security

/// Keychain secret storage (moved out of Redis.m). Generic-password items in
/// the login keychain, one per connection + field. Secrets never reach
/// connections.json; the JSON only records that one exists.
enum ARDMKeychain {

    private static let serviceName = "me.qii404.ardm.native.credentials"

    private static func baseQuery(forAccount account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
        ]
    }

    @discardableResult
    static func setSecret(_ secret: String, forAccount account: String) -> Bool {
        guard !account.isEmpty else { return false }
        guard !secret.isEmpty else { return deleteSecret(forAccount: account) }
        let query = baseQuery(forAccount: account)
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = Data(secret.utf8)
        // Available after first unlock so a background reconnect still works, but
        // never synced to iCloud or other devices.
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        item[kSecAttrSynchronizable as String] = false
        var status = SecItemAdd(item as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let update = [kSecValueData as String: Data(secret.utf8)]
            status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        }
        return status == errSecSuccess
    }

    static func secret(forAccount account: String) -> String? {
        guard !account.isEmpty else { return nil }
        // Automation hook: an ad-hoc re-signed build triggers a macOS keychain prompt
        // on every launch, which blocks a headless UI screenshot run.
        if getenv("ARDM_SKIP_KEYCHAIN") != nil { return nil }
        var query = baseQuery(forAccount: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func deleteSecret(forAccount account: String) -> Bool {
        guard !account.isEmpty else { return false }
        let status = SecItemDelete(baseQuery(forAccount: account) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    static func hasSecret(forAccount account: String) -> Bool {
        guard !account.isEmpty else { return false }
        var query = baseQuery(forAccount: account)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }
}
