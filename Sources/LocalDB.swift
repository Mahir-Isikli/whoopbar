import Foundation
import SQLite3

let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct HRPoint: Identifiable {
    let date: Date
    let bpm: Double
    var id: TimeInterval { date.timeIntervalSince1970 }
}

/// Local SQLite store at ~/Library/Application Support/WhoopBar/whoop-local.db.
/// Two tables:
///   hr_samples(ts, bpm)  — live BLE heart rate, ~1 Hz (ts = unix seconds, so dedupes per second).
///                          This is intraday HR the Whoop cloud API does NOT expose.
///   daily(date, …)       — mirror of the server's daily history for offline use.
final class LocalDB {
    static let shared = LocalDB()
    private var db: OpaquePointer?
    private let q = DispatchQueue(label: "com.mahir.whoopbar.localdb")

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WhoopBar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("whoop-local.db").path
        if sqlite3_open(path, &db) == SQLITE_OK {
            exec("PRAGMA journal_mode=WAL;")
            exec("CREATE TABLE IF NOT EXISTS hr_samples (ts INTEGER PRIMARY KEY, bpm INTEGER);")
            exec("CREATE TABLE IF NOT EXISTS daily (date TEXT PRIMARY KEY, recovery REAL, hrv REAL, rhr REAL, strain REAL, sleep_perf REAL, sleep_hours REAL);")
            exec("DELETE FROM hr_samples WHERE ts < \(Int(Date().timeIntervalSince1970) - 90 * 86400);")  // 90-day retention
        }
    }

    private func exec(_ sql: String) { sqlite3_exec(db, sql, nil, nil, nil) }

    func insertHR(_ bpm: Int) {
        let ts = Int(Date().timeIntervalSince1970)
        q.async {
            var st: OpaquePointer?
            if sqlite3_prepare_v2(self.db, "INSERT OR REPLACE INTO hr_samples (ts,bpm) VALUES (?,?)", -1, &st, nil) == SQLITE_OK {
                sqlite3_bind_int64(st, 1, sqlite3_int64(ts))
                sqlite3_bind_int(st, 2, Int32(bpm))
                sqlite3_step(st)
            }
            sqlite3_finalize(st)
        }
    }

    func upsertDaily(_ d: DayPoint) {
        q.async {
            var st: OpaquePointer?
            if sqlite3_prepare_v2(self.db, "INSERT OR REPLACE INTO daily (date,recovery,hrv,rhr,strain,sleep_perf,sleep_hours) VALUES (?,?,?,?,?,?,?)", -1, &st, nil) == SQLITE_OK {
                sqlite3_bind_text(st, 1, d.date, -1, SQLITE_TRANSIENT)
                self.bindOpt(st, 2, d.recovery); self.bindOpt(st, 3, d.hrv); self.bindOpt(st, 4, d.rhr)
                self.bindOpt(st, 5, d.strain); self.bindOpt(st, 6, d.sleep_perf); self.bindOpt(st, 7, d.sleep_hours)
                sqlite3_step(st)
            }
            sqlite3_finalize(st)
        }
    }

    private func bindOpt(_ st: OpaquePointer?, _ idx: Int32, _ v: Double?) {
        if let v { sqlite3_bind_double(st, idx, v) } else { sqlite3_bind_null(st, idx) }
    }

    /// HR samples on or after `since`, oldest first.
    func hrSamples(since: Date) -> [HRPoint] {
        var out: [HRPoint] = []
        q.sync {
            var st: OpaquePointer?
            if sqlite3_prepare_v2(self.db, "SELECT ts,bpm FROM hr_samples WHERE ts>=? ORDER BY ts", -1, &st, nil) == SQLITE_OK {
                sqlite3_bind_int64(st, 1, sqlite3_int64(Int(since.timeIntervalSince1970)))
                while sqlite3_step(st) == SQLITE_ROW {
                    out.append(HRPoint(date: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(st, 0))),
                                       bpm: Double(sqlite3_column_int(st, 1))))
                }
            }
            sqlite3_finalize(st)
        }
        return out
    }
}
