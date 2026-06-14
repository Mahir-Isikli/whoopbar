import Foundation
import Darwin

/// Tiny loopback HTTP listener for the OAuth redirect (RFC 8252 native-app flow).
/// WHOOP redirects the browser to http://localhost:8973/callback?code=… and this catches it.
/// Loopback-only bind, so no macOS incoming-connection firewall prompt.
enum LoopbackServer {
    static func listenForCode(port: UInt16, timeoutSec: Int32 = 300) -> String? {
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

        var buf = [UInt8](repeating: 0, count: 8192)
        let n = read(client, &buf, buf.count)
        let request = n > 0 ? (String(bytes: buf[0..<n], encoding: .utf8) ?? "") : ""
        let code = parseCode(request)

        let html = "<html><body style=\"font-family:-apple-system;text-align:center;margin-top:80px;color:#222\">"
            + "<h2>\u{2713} Connected to WhoopBar</h2><p>You can close this tab and return to the app.</p></body></html>"
        let resp = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nConnection: close\r\n"
            + "Content-Length: \(html.utf8.count)\r\n\r\n\(html)"
        _ = resp.withCString { write(client, $0, strlen($0)) }
        return code
    }

    private static func parseCode(_ request: String) -> String? {
        guard let firstLine = request.split(separator: "\r\n").first else { return nil }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        guard let query = parts[1].split(separator: "?").dropFirst().first else { return nil }
        for pair in query.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.first == "code", kv.count == 2 { return String(kv[1]).removingPercentEncoding }
        }
        return nil
    }
}
