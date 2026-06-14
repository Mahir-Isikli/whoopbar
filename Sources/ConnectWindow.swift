import AppKit
import SwiftUI

/// Hosts the Connect flow in a real AppKit window so it survives the browser OAuth round-trip
/// (the menu-bar popover closes the moment focus leaves it). Created on demand, never at launch.
@MainActor
final class ConnectWindowController: NSObject, NSWindowDelegate {
    static let shared = ConnectWindowController()
    private var window: NSWindow?

    func show(auth: WhoopAuth) {
        NSApp.setActivationPolicy(.regular)            // so the window can take keyboard focus
        NSApp.activate(ignoringOtherApps: true)
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let root = ConnectView(auth: auth, onClose: { [weak self] in self?.window?.close() })
        let hosting = NSHostingController(rootView: root)
        let w = NSWindow(contentViewController: hosting)
        w.title = "Connect Whoop"
        w.styleMask = [.titled, .closable]
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        NSApp.setActivationPolicy(.accessory)          // back to menu-bar-only
    }
}
