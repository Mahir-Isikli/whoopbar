import Foundation
import SwiftUI

/// Lightweight over-the-air update *notifier*. It does NOT replace the app bundle itself (that
/// path is fragile for ad-hoc / non-notarized apps: App Management TCC, quarantine, code-sign
/// pinning). Instead it asks GitHub once a day whether a newer release tag exists and, if so,
/// surfaces a small pill. Tapping it sends the user to the release (or they just `brew upgrade`).
@MainActor
final class UpdateChecker: ObservableObject {
    @Published var latest: String?          // newest version string available upstream, e.g. "0.2.3"
    @Published var releaseURL: URL?

    private let repo = "Mahir-Isikli/whoopbar"
    private let current = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"
    private var timer: Timer?

    /// True when the upstream tag is strictly newer than the running build.
    var updateAvailable: Bool {
        guard let latest else { return false }
        return Self.compare(latest, current) > 0
    }

    init() {
        Task { await check() }
        // Re-check daily. .common mode so it still fires while the menu-bar popover is open.
        let t = Timer(timeInterval: 86_400, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.check() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func check() async {
        guard var req = URL(string: "https://api.github.com/repos/\(repo)/releases/latest").map({ URLRequest(url: $0) }) else { return }
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("whoopbar/\(current)", forHTTPHeaderField: "User-Agent")   // GitHub API requires a UA
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        let tag = (j["tag_name"] as? String).map { $0.hasPrefix("v") ? String($0.dropFirst()) : $0 }
        if let tag { latest = tag }
        if let urlStr = j["html_url"] as? String { releaseURL = URL(string: urlStr) }
    }

    /// Compare dotted version strings numerically. Returns 1 if a > b, -1 if a < b, 0 if equal.
    static func compare(_ a: String, _ b: String) -> Int {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y ? 1 : -1 }
        }
        return 0
    }
}
