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
        installEditMenu()                              // so Cmd+V / Cmd+C work in the text fields
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
        NSApp.mainMenu = nil                           // drop the temporary menu
        NSApp.setActivationPolicy(.accessory)          // back to menu-bar-only
    }

    /// An agent app (LSUIElement) has no menu bar, so the standard text-editing shortcuts
    /// (Cmd+V/C/X/A) have nothing to route to — that's why pasting into the fields did nothing.
    /// Install a minimal Edit menu while the Connect window is up so the field editor receives them.
    private func installEditMenu() {
        let main = NSMenu()
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        editItem.submenu = edit
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        NSApp.mainMenu = main
    }
}
