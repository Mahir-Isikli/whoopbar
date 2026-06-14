import SwiftUI

@main
struct WhoopBarApp: App {
    @StateObject private var bt = BluetoothManager()
    @StateObject private var store = WhoopStore()
    @StateObject private var auth = WhoopAuth()

    var body: some Scene {
        MenuBarExtra {
            PopoverView()
                .environmentObject(bt)
                .environmentObject(store)
                .environmentObject(auth)
        } label: {
            // Live heart rate in the menu bar; "–" when the strap isn't connected.
            Image(systemName: bt.heartRate != nil ? "heart.fill" : "heart")
            Text(bt.heartRate.map { "\($0)" } ?? "–")
        }
        .menuBarExtraStyle(.window)
    }
}
