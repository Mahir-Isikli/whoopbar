import Foundation
import CoreBluetooth

/// Connects to the WHOOP strap over BLE and reads the STANDARD Heart Rate service (0x180D)
/// plus Battery (0x180F). It only ever discovers those two standard services, never the
/// proprietary `fd4b…` service, and never bonds/pairs — so it cannot disturb the iPhone's
/// connection. BLE supports multiple simultaneous central connections; reading the open HR
/// notify characteristic alongside the phone was verified to work.
final class BluetoothManager: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    @Published var heartRate: Int?
    @Published var batteryLevel: Int?
    @Published var connected = false
    @Published var state: Status = .unknown
    @Published var deviceName = "WHOOP"

    enum Status { case unknown, off, searching, connecting, connected }

    private var central: CBCentralManager!
    private var strap: CBPeripheral?

    private let hrService  = CBUUID(string: "180D")
    private let hrChar     = CBUUID(string: "2A37")
    private let battService = CBUUID(string: "180F")
    private let battChar    = CBUUID(string: "2A19")

    // Staleness: if HR notifications dry up (signal too weak but link not yet dropped),
    // clear the value rather than freezing a stale number in the menu bar.
    private var lastHR = Date.distantPast
    private let staleAfter: TimeInterval = 8
    private var staleTimer: Timer?

    override init() {
        super.init()
        // Deliver delegate callbacks on the main queue so we can publish directly.
        central = CBCentralManager(delegate: self, queue: .main)
        staleTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.checkStale()
        }
    }

    private func checkStale() {
        if heartRate != nil, Date().timeIntervalSince(lastHR) > staleAfter {
            heartRate = nil                       // signal lost — show "–", not a frozen number
            if state == .connected { state = .searching }
        }
    }

    private func startScan() {
        guard central.state == .poweredOn else { return }
        if state != .connected { state = .searching }
        // If the strap is already connected at the OS level, grab it directly (fast attach).
        for p in central.retrieveConnectedPeripherals(withServices: [hrService])
        where (p.name ?? "").uppercased().contains("WHOOP") {
            strap = p; p.delegate = self; central.connect(p, options: nil); return
        }
        central.scanForPeripherals(withServices: [hrService], options: nil)
    }

    // MARK: CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        DLog.write("central state = \(c.state.rawValue)")
        switch c.state {
        case .poweredOn: startScan()
        case .poweredOff, .unauthorized, .unsupported:
            state = .off; connected = false; heartRate = nil
        default:
            state = .unknown
        }
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? p.name ?? ""
        DLog.write("discovered '\(name)' rssi=\(RSSI)")
        guard name.uppercased().contains("WHOOP") else { return }   // ignore other HR straps/watches
        deviceName = name
        strap = p
        p.delegate = self
        c.stopScan()
        state = .connecting
        c.connect(p, options: nil)
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        DLog.write("connected to \(p.name ?? "?")")
        connected = true
        state = .connected
        // Only the two standard services — never the proprietary fd4b service.
        p.discoverServices([hrService, battService])
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        DLog.write("disconnected (\(error?.localizedDescription ?? "clean"))")
        connected = false
        heartRate = nil
        state = .searching
        // Native pending reconnect: CoreBluetooth completes this automatically — and
        // power-efficiently — the moment the strap is back in range. No polling.
        if let strap { c.connect(strap, options: nil) }
        startScan()   // fallback discovery path
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        DLog.write("failed to connect (\(error?.localizedDescription ?? "?"))")
        connected = false
        state = .searching
        if let strap { c.connect(strap, options: nil) }   // keep a pending reconnect alive
    }

    // MARK: CBPeripheralDelegate

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        for s in p.services ?? [] {
            if s.uuid == hrService { p.discoverCharacteristics([hrChar], for: s) }
            if s.uuid == battService { p.discoverCharacteristics([battChar], for: s) }
        }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        for ch in s.characteristics ?? [] {
            if ch.uuid == hrChar { p.setNotifyValue(true, for: ch) }
            if ch.uuid == battChar { p.readValue(for: ch); p.setNotifyValue(true, for: ch) }
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        guard let data = ch.value else { return }
        if ch.uuid == hrChar {
            if let hr = Self.parseHeartRate(data) {
                heartRate = hr
                lastHR = Date()
                if state != .connected { state = .connected }
                if !connected { connected = true }
                LocalDB.shared.insertHR(hr)   // log to local SQLite (intraday HR history)
            }
        } else if ch.uuid == battChar, let b = data.first {
            batteryLevel = Int(b)
            DLog.write("battery = \(b)%")
        }
    }

    /// Parse a Heart Rate Measurement (0x2A37) packet: bit0 of the flags byte selects 8- vs 16-bit HR.
    static func parseHeartRate(_ data: Data) -> Int? {
        let bytes = [UInt8](data)
        guard let flags = bytes.first else { return nil }
        if flags & 0x01 == 0 {
            return bytes.count >= 2 ? Int(bytes[1]) : nil
        } else {
            return bytes.count >= 3 ? Int(bytes[1]) | (Int(bytes[2]) << 8) : nil
        }
    }
}
