import Foundation
import SwiftUI
import AppKit

private enum AuthError: Error { case noCreds, badResponse, http(Int), keychainWrite }

/// Clean a pasted Client ID / Secret: drop whitespace + invisible chars (WHOOP copies a
/// trailing newline) and normalize any fancy dash glyphs back to a plain hyphen.
func cleanCredential(_ s: String) -> String {
    let dashes: Set<Character> = ["\u{2010}", "\u{2011}", "\u{2012}", "\u{2013}", "\u{2014}", "\u{2015}", "\u{2212}"]
    let invisibles: Set<Character> = ["\u{200B}", "\u{200C}", "\u{200D}", "\u{FEFF}", "\u{2060}"]
    return String(s.compactMap { ch -> Character? in
        if ch.isWhitespace || invisibles.contains(ch) { return nil }
        return dashes.contains(ch) ? "-" : ch
    })
}

private extension CharacterSet {
    static let formValue = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
}
private extension Double {
    func rounded(toPlaces p: Int) -> Double { let m = pow(10.0, Double(p)); return (self * m).rounded() / m }
}

/// In-app WHOOP connection (Model A: the user's OWN developer app). Does the OAuth loopback
/// flow, stores credentials/tokens in the Keychain, fetches recovery/sleep/cycle/workout, and
/// writes the same history.json the charts read. No Terminal, no Python. Refreshes on a timer.
@MainActor
final class WhoopAuth: ObservableObject {
    enum Status: Equatable { case disconnected, connecting, syncing, connected, failed(String) }
    @Published var status: Status = .disconnected

    nonisolated static let historyUpdated = Notification.Name("WhoopHistoryUpdated")

    private let api = "https://api.prod.whoop.com/developer"
    private let tokenURL = "https://api.prod.whoop.com/oauth/oauth2/token"
    private let authBase = "https://api.prod.whoop.com/oauth/oauth2/auth"
    private let redirect = "http://localhost:8973/callback"
    private let scopes = "offline read:recovery read:cycles read:sleep read:workout read:profile"
    private let port: UInt16 = 8973
    private var timer: Timer?
    private var syncTask: Task<Void, Never>?   // serializes sync(): never two refreshes at once

    var isConnected: Bool { switch status { case .connected, .syncing: return true; default: return false } }

    init() {
        if Keychain.get("refreshToken") != nil {
            status = .connected
            startTimer()
            Task { await sync() }
        }
    }

    func connect(clientId: String, clientSecret: String) {
        let cid = cleanCredential(clientId)
        let cs = cleanCredential(clientSecret)
        guard !cid.isEmpty, !cs.isEmpty else { status = .failed("Enter both Client ID and Secret."); return }
        Keychain.set("clientId", cid)
        Keychain.set("clientSecret", cs)
        status = .connecting
        let expectedState = UUID().uuidString
        Task {
            var comps = URLComponents(string: authBase)!
            comps.queryItems = [
                .init(name: "response_type", value: "code"),
                .init(name: "client_id", value: cid),
                .init(name: "redirect_uri", value: redirect),
                .init(name: "scope", value: scopes),
                .init(name: "state", value: expectedState),
            ]
            guard let authURL = comps.url else { status = .failed("Internal error."); return }
            let codeTask = Task.detached(priority: .userInitiated) { LoopbackServer.listenForCode(port: 8973) }
            NSWorkspace.shared.open(authURL)
            guard let result = await codeTask.value else {
                status = .failed("Login timed out or was cancelled."); return
            }
            // Reject a callback whose state doesn't match the one we sent (CSRF protection).
            guard result.state == expectedState else {
                status = .failed("Login verification failed. Please try connecting again."); return
            }
            let code = result.code
            do {
                try await exchange(code: code, clientId: cid, clientSecret: cs)
                await sync()
                startTimer()
            } catch {
                status = .failed("Couldn't connect. Double-check your keys and the redirect URL.")
            }
        }
    }

    func disconnect() {
        clearTokens()
        ["clientId", "clientSecret"].forEach { Keychain.set($0, nil) }
        status = .disconnected
    }

    /// Drop the OAuth tokens (and stop the refresh timer) but KEEP the client id/secret, so a dead
    /// token chain doesn't force the user to re-paste their developer credentials on reconnect.
    private func clearTokens() {
        timer?.invalidate(); timer = nil
        ["accessToken", "refreshToken", "expiry"].forEach { Keychain.set($0, nil) }
    }

    // MARK: tokens

    private func exchange(code: String, clientId: String, clientSecret: String) async throws {
        let data = try await postForm(tokenURL, [
            "grant_type": "authorization_code", "code": code, "redirect_uri": redirect,
            "client_id": clientId, "client_secret": clientSecret,
        ])
        try saveTokens(data)
    }

    private func refreshIfNeeded() async throws {
        let exp = Double(Keychain.get("expiry") ?? "0") ?? 0
        if Keychain.get("accessToken") != nil, Date().timeIntervalSince1970 < exp { return }
        guard let rt = Keychain.get("refreshToken"),
              let cid = Keychain.get("clientId"),
              let cs = Keychain.get("clientSecret") else { throw AuthError.noCreds }
        let data = try await postForm(tokenURL, [
            "grant_type": "refresh_token", "refresh_token": rt,
            "client_id": cid, "client_secret": cs, "scope": "offline",
        ])
        try saveTokens(data)
    }

    private func saveTokens(_ data: Data) throws {
        guard let j = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let at = j["access_token"] as? String else { throw AuthError.badResponse }
        let expIn = (j["expires_in"] as? NSNumber)?.doubleValue ?? 3600
        // Write the rotating (single-use) refresh token FIRST. If a later write fails, we still
        // hold the newest refresh token rather than a consumed one, so we can recover.
        if let rt = j["refresh_token"] as? String {
            guard Keychain.set("refreshToken", rt) else { throw AuthError.keychainWrite }
        }
        guard Keychain.set("accessToken", at) else { throw AuthError.keychainWrite }
        Keychain.set("expiry", String(Date().addingTimeInterval(expIn - 60).timeIntervalSince1970))
    }

    // MARK: sync

    /// Coalescing entry point: if a sync is already running, join it instead of starting a second.
    /// This guarantees only one token refresh is ever in flight, so the single-use rotating
    /// refresh token can never be spent twice (which would revoke the whole chain).
    func sync() async {
        if let running = syncTask { await running.value; return }
        let task = Task { await runSync() }
        syncTask = task
        await task.value
        syncTask = nil
    }

    private func runSync() async {
        guard Keychain.get("refreshToken") != nil else { return }
        if isConnected { status = .syncing }
        do {
            try await refreshIfNeeded()
            guard let at = Keychain.get("accessToken") else { throw AuthError.noCreds }
            async let rec = fetchAll("/v2/recovery", at)
            async let slp = fetchAll("/v2/activity/sleep", at)
            async let cyc = fetchAll("/v2/cycle", at)
            async let wko = fetchAll("/v2/activity/workout", at)
            let days = buildHistory(try await rec, try await slp, try await cyc, try await wko)
            writeHistory(days)
            status = .connected
            NotificationCenter.default.post(name: Self.historyUpdated, object: nil)
        } catch AuthError.http(let code) where code == 400 || code == 401 {
            // Refresh token rejected / access token invalid: the token chain is dead. Drop the
            // tokens and require a reconnect instead of retrying a consumed token forever.
            clearTokens()
            status = .failed("Whoop sign-in expired. Reconnect from the menu.")
        } catch AuthError.keychainWrite {
            clearTokens()
            status = .failed("Couldn't save your Whoop login. Reconnect from the menu.")
        } catch {
            // Transient (network, rate limit, 5xx): keep the connection and let the timer retry.
            status = .failed("Sync failed. Open the menu to retry.")
        }
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.sync() }
        }
    }

    // MARK: networking

    private func postForm(_ urlStr: String, _ form: [String: String]) async throws -> Data {
        var req = URLRequest(url: URL(string: urlStr)!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("whoopbar/1.0", forHTTPHeaderField: "User-Agent")
        req.httpBody = form.map {
            "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .formValue) ?? $0.value)"
        }.joined(separator: "&").data(using: .utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw AuthError.http((resp as? HTTPURLResponse)?.statusCode ?? -1)
        }
        return data
    }

    private func fetchAll(_ path: String, _ token: String) async throws -> [[String: Any]] {
        var out: [[String: Any]] = []
        var url: URL? = URL(string: api + path + "?limit=25")
        while let u = url {
            var req = URLRequest(url: u)
            req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            req.setValue("whoopbar/1.0", forHTTPHeaderField: "User-Agent")
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw AuthError.http((resp as? HTTPURLResponse)?.statusCode ?? -1)
        }
            let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            out += (j["records"] as? [[String: Any]]) ?? []
            if let nt = j["next_token"] as? String, !nt.isEmpty {
                url = URL(string: api + path + "?limit=25&nextToken=" + nt)
            } else { url = nil }
        }
        return out
    }

    // MARK: history

    private func dnum(_ a: Any?) -> Double? { (a as? NSNumber)?.doubleValue }
    private func inum(_ a: Any?) -> Int? { (a as? NSNumber)?.intValue }

    private func buildHistory(_ recovery: [[String: Any]], _ sleep: [[String: Any]],
                              _ cycles: [[String: Any]], _ workouts: [[String: Any]]) -> [DayPoint] {
        var rec: [Int: [String: Any]] = [:]
        for r in recovery where (r["score_state"] as? String) == "SCORED" {
            if let cid = inum(r["cycle_id"]) { rec[cid] = (r["score"] as? [String: Any]) ?? [:] }
        }
        var best: [Int: (inbed: Double, score: [String: Any], ss: [String: Any])] = [:]
        for s in sleep where (s["score_state"] as? String) == "SCORED" && !((s["nap"] as? Bool) ?? false) {
            guard let cid = inum(s["cycle_id"]) else { continue }
            let sc = (s["score"] as? [String: Any]) ?? [:]
            let ss = (sc["stage_summary"] as? [String: Any]) ?? [:]
            let inbed = dnum(ss["total_in_bed_time_milli"]) ?? 0
            if best[cid] == nil || inbed > best[cid]!.inbed { best[cid] = (inbed, sc, ss) }
        }
        let scored = cycles.filter { ($0["score_state"] as? String) == "SCORED" }
            .sorted { (($0["start"] as? String) ?? "") < (($1["start"] as? String) ?? "") }
        // WHOOP "cycles" are physiological days (wake-to-wake), so two cycles can fall on the same
        // calendar date while another date has none. Collapse to one representative point per date,
        // preferring the cycle that actually has a recovery score, then the one with more sleep,
        // then more strain — that's the "main" day, matching what the WHOOP app shows.
        var byDate: [String: DayPoint] = [:]
        for c in scored {
            guard let cid = inum(c["id"]) else { continue }
            let cs = (c["score"] as? [String: Any]) ?? [:]
            let r = rec[cid] ?? [:]
            var sleepHours: Double?
            if let b = best[cid] {
                let inbed = dnum(b.ss["total_in_bed_time_milli"]) ?? 0
                let awake = dnum(b.ss["total_awake_time_milli"]) ?? 0
                sleepHours = ((inbed - awake) / 3_600_000).rounded(toPlaces: 2)
            }
            let dp = DayPoint(
                date: String(((c["start"] as? String) ?? "").prefix(10)),
                strain: dnum(cs["strain"]).map { $0.rounded(toPlaces: 2) },
                recovery: dnum(r["recovery_score"]),
                hrv: dnum(r["hrv_rmssd_milli"]).map { $0.rounded(toPlaces: 1) },
                rhr: dnum(r["resting_heart_rate"]),
                sleep_perf: best[cid].flatMap { dnum($0.score["sleep_performance_percentage"]) },
                sleep_hours: sleepHours)
            if let existing = byDate[dp.date], rank(existing) >= rank(dp) { continue }
            byDate[dp.date] = dp
        }
        return byDate.values.sorted { $0.date < $1.date }
    }

    /// Higher = better representative of a calendar day: has recovery first, then more sleep, then strain.
    private func rank(_ d: DayPoint) -> Double {
        (d.recovery != nil ? 1_000_000 : 0) + (d.sleep_hours ?? 0) * 1_000 + (d.strain ?? 0)
    }

    private func writeHistory(_ days: [DayPoint]) {
        struct Payload: Encodable { let generated_at: String; let days: [DayPoint] }
        let payload = Payload(generated_at: ISO8601DateFormatter().string(from: Date()), days: days)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: WhoopStore.cacheURL, options: .atomic)
    }
}
