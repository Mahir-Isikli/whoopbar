import Foundation
import SwiftUI

struct DayPoint: Codable, Identifiable {
    let date: String
    let strain: Double?
    let recovery: Double?
    let hrv: Double?
    let rhr: Double?
    let sleep_perf: Double?
    let sleep_hours: Double?
    var id: String { date }

    private static let fmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = TimeZone(identifier: "UTC"); return f
    }()
    var day: Date { DayPoint.fmt.date(from: date) ?? Date.distantPast }
}

private struct History: Codable { let generated_at: String?; let days: [DayPoint] }

/// Loads the daily series the server collector publishes at /root/whoop-data/history.json.
/// Reads over SSH (everything-server alias, BatchMode so it never hangs on a prompt) and
/// caches the last good copy locally so the popover renders instantly and works offline.
final class WhoopStore: ObservableObject {
    @Published var days: [DayPoint] = []
    @Published var todayHR: [HRPoint] = []
    @Published var lastUpdated: Date?
    @Published var loading = false
    @Published var errorText: String?

    private var timer: Timer?
    private var hrTimer: Timer?

    init() {
        loadCache()
        refresh()
        loadTodayHR()
        timer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in self?.refresh() }
        // Keep the day-view HR series fresh while the popover is open.
        hrTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in self?.loadTodayHR() }
    }

    /// Load today's intraday HR samples from the local SQLite store.
    func loadTodayHR() {
        DispatchQueue.global(qos: .utility).async {
            let start = Calendar.current.startOfDay(for: Date())
            let pts = LocalDB.shared.hrSamples(since: start)
            DispatchQueue.main.async { self.todayHR = pts }
        }
    }

    var latest: DayPoint? { days.last(where: { $0.recovery != nil || $0.strain != nil }) ?? days.last }

    /// Refresh the daily history. Source of truth is the local file
    /// `~/Library/Application Support/WhoopBar/history.json`, which the collector writes.
    /// If the `WHOOPBAR_SYNC` env var is set (a shell command that prints history JSON to
    /// stdout, e.g. pulling from a remote server), it runs first and updates that file.
    func refresh() {
        guard !loading else { return }
        loading = true
        errorText = nil
        DispatchQueue.global(qos: .userInitiated).async {
            if let cmd = ProcessInfo.processInfo.environment["WHOOPBAR_SYNC"], !cmd.isEmpty,
               let text = Self.runShell(cmd), let data = text.data(using: .utf8),
               (try? JSONDecoder().decode(History.self, from: data)) != nil {
                try? data.write(to: Self.cacheURL)   // sync command produced fresh history
            }
            let data = try? Data(contentsOf: Self.cacheURL)
            DispatchQueue.main.async {
                self.loading = false
                guard let data, let decoded = try? JSONDecoder().decode(History.self, from: data) else {
                    self.errorText = "No history yet — run the collector"; return
                }
                self.days = decoded.days
                self.lastUpdated = Date()
                decoded.days.forEach { LocalDB.shared.upsertDaily($0) }   // mirror to local SQLite
            }
        }
    }

    /// Run a shell command, returning stdout on success.
    private static func runShell(_ cmd: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", cmd]
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? String(data: data, encoding: .utf8) : nil
    }

    // MARK: cache

    /// Local history file the collector writes and the app reads.
    static var cacheURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WhoopBar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }

    private func loadCache() {
        guard let data = try? Data(contentsOf: Self.cacheURL),
              let decoded = try? JSONDecoder().decode(History.self, from: data) else { return }
        days = decoded.days
    }
}
