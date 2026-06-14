import Foundation
import ServiceManagement

/// "Start at login" via SMAppService (macOS 13+). The app registers itself, so users
/// never have to open System Settings. Skipped when a LaunchAgent already manages startup
/// (the source/`install.sh` path) to avoid launching twice.
enum LoginItem {
    static var launchdManaged: Bool {
        FileManager.default.fileExists(atPath:
            (("~/Library/LaunchAgents/com.mahir.whoopbar.plist") as NSString).expandingTildeInPath)
    }

    static var available: Bool {
        if #available(macOS 13, *) { return !launchdManaged }
        return false
    }

    static var enabled: Bool {
        if #available(macOS 13, *) { return SMAppService.mainApp.status == .enabled }
        return false
    }

    @discardableResult
    static func set(_ on: Bool) -> Bool {
        guard #available(macOS 13, *) else { return false }
        do {
            if on {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            } else {
                try SMAppService.mainApp.unregister()
            }
            return true
        } catch {
            NSLog("WhoopBar login item error: \(error)")
            return false
        }
    }
}
