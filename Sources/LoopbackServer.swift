import Foundation
import Darwin

/// Tiny loopback HTTP listener for the OAuth redirect (RFC 8252 native-app flow).
/// WHOOP redirects the browser to http://localhost:8973/callback?code=… and this catches it.
/// Loopback-only bind, so no macOS incoming-connection firewall prompt.
enum LoopbackServer {
    static func listenForCode(port: UInt16, timeoutSec: Int32 = 300) -> (code: String, state: String?)? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 1) == 0 else { return nil }

        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&pfd, 1, timeoutSec * 1000) > 0 else { return nil }

        let client = accept(fd, nil, nil)
        guard client >= 0 else { return nil }
        defer { close(client) }

        // Accumulate until the end of the HTTP headers — TCP may split the request across reads,
        // even on loopback. (Bounded so a malformed/huge request can't spin forever.)
        var request = ""
        var buf = [UInt8](repeating: 0, count: 8192)
        while !request.contains("\r\n\r\n") {
            let n = read(client, &buf, buf.count)
            if n <= 0 { break }
            request += String(bytes: buf[0..<n], encoding: .utf8) ?? ""
            if request.utf8.count > 65_536 { break }
        }
        let parsed = parseCode(request)

        let html = #"""
<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>WhoopBar</title>
<style>
:root{color-scheme:light dark}
*{box-sizing:border-box}
body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;
 font-family:-apple-system,BlinkMacSystemFont,"SF Pro Text",system-ui,sans-serif;background:#f4f4f6;color:#1c1c1e}
.card{background:#fff;border-radius:24px;padding:48px 56px;text-align:center;box-shadow:0 18px 50px rgba(0,0,0,.10);max-width:380px}
.ring{width:66px;height:66px;border-radius:50%;background:#43c785;display:flex;align-items:center;justify-content:center;margin:0 auto 24px}
.ring svg{width:32px;height:32px}
h1{font-size:21px;font-weight:600;letter-spacing:-.015em;margin:0 0 8px}
p{font-size:14px;line-height:1.45;margin:0;opacity:.55}
@media (prefers-color-scheme:dark){body{background:#161618;color:#f2f2f7}.card{background:#1f1f22;box-shadow:none}}
</style></head>
<body><div class="card">
<div class="ring"><svg viewBox="0 0 24 24" fill="none" stroke="#fff" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"><path d="M5 12.5l5 5 9-10.5"/></svg></div>
<h1>Connected to WhoopBar</h1>
<p>You can close this tab and head back to the app — your data is syncing now.</p>
</div></body></html>
"""#
        let resp = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nConnection: close\r\n"
            + "Content-Length: \(html.utf8.count)\r\n\r\n\(html)"
        _ = resp.withCString { write(client, $0, strlen($0)) }
        return parsed
    }

    /// Extract `code` and `state` from the redirect request line. Only accepts the /callback path,
    /// so stray browser fetches (favicon, preconnect) on this port can't be mistaken for the redirect.
    private static func parseCode(_ request: String) -> (code: String, state: String?)? {
        guard let firstLine = request.split(separator: "\r\n").first else { return nil }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2, parts[1].hasPrefix("/callback") else { return nil }
        guard let query = parts[1].split(separator: "?").dropFirst().first else { return nil }
        var code: String?
        var state: String?
        for pair in query.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            let value = String(kv[1]).removingPercentEncoding
            if kv[0] == "code" { code = value }
            else if kv[0] == "state" { state = value }
        }
        guard let code else { return nil }
        return (code, state)
    }
}
