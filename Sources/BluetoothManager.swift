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

    // Connect watchdog: CoreBluetooth's connect() never times out on its own, so a weak/half-open
    // attempt can park us in `.connecting` ("Linking") forever. Abandon it and rescan instead.
    private var connectTimeout: Timer?
    private let connectTimeoutAfter: TimeInterval = 12
    private var lastScanKick = Date.distantPast

    override init() {
        super.init()
        // Deliver delegate callbacks on the main queue so we can publish directly.
        central = CBCentralManager(delegate: self, queue: .main)
        // .common mode so the timer keeps firing even while the menu-bar popover is open
        // (menu tracking switches the run loop out of .default mode, which would pause it).
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.checkStale() }
        RunLoop.main.add(t, forMode: .common)
        staleTimer = t
    }

    private func checkStale() {
        if heartRate != nil, Date().timeIntervalSince(lastHR) > staleAfter {
            heartRate = nil                       // signal lost — show "–", not a frozen number
            if state == .connected { state = .searching }
        }
        // Keep actively looking while unlinked so a strap returning to range reconnects on its own.
        // (A stalled `.connecting` is handled by the connect watchdog, so don't rescan over it.)
        if state == .searching, central?.state == .poweredOn,
           Date().timeIntervalSince(lastScanKick) > 15 {
            startScan()
        }
    }

    private func armConnectTimeout() {
        connectTimeout?.invalidate()
        let t = Timer(timeInterval: connectTimeoutAfter, repeats: false) { [weak self] _ in
            guard let self, self.state == .connecting, let s = self.strap else { return }
            DLog.write("connect timed out — cancelling and rescanning")
            self.central.cancelPeripheralConnection(s)
            self.state = .searching
            self.startScan()
        }
        RunLoop.main.add(t, forMode: .common)   // keep firing while the menu is open
        connectTimeout = t
    }

    private func cancelConnectTimeout() { connectTimeout?.invalidate(); connectTimeout = nil }

    private func startScan() {
        guard central.state == .poweredOn else { return }
        lastScanKick = Date()
        if state != .connected { state = .searching }
        // If the strap is already connected at the OS level, grab it directly (fast attach).
        for p in central.retrieveConnectedPeripherals(withServices: [hrService])
        where (p.name ?? "").uppercased().contains("WHOOP") {
            strap = p; p.delegate = self
            guard p.state == .disconnected else { return }   // already linking/linked — no duplicate connect
            state = .connecting
            central.connect(p, options: nil)
            armConnectTimeout()
            return
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
        // If a reconnect is already in flight for this peripheral (e.g. the pending connect from
        // didDisconnect), don't fire a second connect — two connects mean two didConnect callbacks
        // and duplicate HR rows.
        guard p.state == .disconnected else { return }
        state = .connecting
        c.connect(p, options: nil)
        armConnectTimeout()
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        DLog.write("connected to \(p.name ?? "?")")
        cancelConnectTimeout()
        connected = true
        state = .connected
        // Only the two standard services — never the proprietary fd4b service.
        p.discoverServices([hrService, battService])
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        DLog.write("disconnected (\(error?.localizedDescription ?? "clean"))")
        cancelConnectTimeout()
        connected = false
        heartRate = nil
        batteryLevel = nil          // don't show a stale battery % while unlinked
        state = .searching
        // Native pending reconnect: CoreBluetooth completes this automatically — and
        // power-efficiently — the moment the strap is back in range. No polling.
        // Only when the radio is on: a connect() while powered off fails instantly and busy-loops.
        if c.state == .poweredOn, let strap { c.connect(strap, options: nil) }
        startScan()   // fallback discovery path (no-op unless powered on)
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        DLog.write("failed to connect (\(error?.localizedDescription ?? "?"))")
        cancelConnectTimeout()
        connected = false
        state = .searching
        // Only retry when powered on — a connect() while the radio is off fails instantly and loops.
        if c.state == .poweredOn, let strap { c.connect(strap, options: nil) }
        startScan()   // resume active discovery (no-op unless powered on)
    }

    // MARK: CBPeripheralDelegate

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            // Discovery failed — drop the link so the reconnect path restarts cleanly instead of
            // sitting "connected" with no characteristics subscribed and no HR ever arriving.
            DLog.write("service discovery failed: \(error.localizedDescription)")
            central.cancelPeripheralConnection(p)
            return
        }
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
        if error != nil { return }   // on error, ch.value may be stale — don't log a bad reading
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
