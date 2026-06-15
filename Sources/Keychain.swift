import Foundation
import Security

/// Minimal Keychain storage for the user's own WHOOP credentials + tokens.
/// Everything stays on this Mac; nothing is uploaded.
enum Keychain {
    private static let service = "com.mahir.whoopbar"

    /// Writes (or, with a nil value, deletes) a credential. Returns false if the add failed so
    /// callers writing rotating tokens can detect a half-written state instead of silently
    /// losing a single-use refresh token.
    @discardableResult
    static func set(_ key: String, _ value: String?) -> Bool {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(base as CFDictionary)
        guard let value, let data = value.data(using: .utf8) else { return true }
        var add = base
        add[kSecValueData as String] = data
        // Keep tokens on THIS device only and never let them sync to iCloud Keychain.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        add[kSecAttrSynchronizable as String] = false
        let status = SecItemAdd(add as CFDictionary, nil)
        return status == errSecSuccess
    }

    static func get(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
