import Foundation

/// Token storage for the user's WHOOP credentials. Uses a local 0600 JSON file rather than the
/// macOS Keychain on purpose: the app is ad-hoc signed (no Apple Developer ID), so its code
/// signature changes on every rebuild/update, and the Keychain then re-prompts for the login
/// password every time a "different" binary tries to read its items. A file in the app's own
/// Application Support folder is readable without any prompt and is plenty for a personal,
/// single-user tool (it never leaves this Mac). Drop-in API-compatible with the old Keychain enum.
enum Secrets {
    private static let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WhoopBar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("credentials.json")
    }()

    private static var cache: [String: String]?

    private static func load() -> [String: String] {
        if let cache { return cache }
        let dict = (try? Data(contentsOf: url))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] } ?? [:]
        cache = dict
        return dict
    }

    static func get(_ key: String) -> String? { load()[key] }

    @discardableResult
    static func set(_ key: String, _ value: String?) -> Bool {
        var d = load()
        if let value { d[key] = value } else { d.removeValue(forKey: key) }
        cache = d
        guard let data = try? JSONSerialization.data(withJSONObject: d) else { return false }
        do {
            try data.write(to: url, options: [.atomic])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return true
        } catch { return false }
    }

    /// One-time move of tokens out of the old Keychain so existing users stay logged in. Reading the
    /// Keychain here may prompt once (the binary's signature no longer matches the item's ACL), but
    /// after this the file is the source of truth and the Keychain is never touched again.
    static func migrateFromKeychainIfNeeded() {
        guard get("refreshToken") == nil else { return }   // already on the file store
        var moved = false
        for k in ["clientId", "clientSecret", "accessToken", "refreshToken", "expiry"] {
            if let v = Keychain.get(k) { set(k, v); moved = true }
        }
        if moved { DLog.write("migrated WHOOP tokens from Keychain to credentials.json") }
    }
}
