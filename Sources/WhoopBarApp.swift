import SwiftUI

@main
struct WhoopBarApp: App {
    @StateObject private var bt = BluetoothManager()
    @StateObject private var store = WhoopStore()
    @StateObject private var auth = WhoopAuth()
    @StateObject private var updates = UpdateChecker()

    var body: some Scene {
        MenuBarExtra {
            PopoverView()
                .environmentObject(bt)
                .environmentObject(store)
                .environmentObject(auth)
                .environmentObject(updates)
        } label: {
            // Live heart rate in the menu bar; "–" when the strap isn't connected.
            Image(systemName: bt.heartRate != nil ? "heart.fill" : "heart")
            Text(bt.heartRate.map { "\($0)" } ?? "–")
            // Low-battery alert: surface the strap's % right in the menu bar (no popover needed)
            // the moment it drops below the threshold, so the warning can't be missed.
            if bt.batteryLow, let b = bt.batteryLevel {
                Image(systemName: "battery.25percent")
                Text("\(b)%")
            }
        }
        .menuBarExtraStyle(.window)
    }
}
