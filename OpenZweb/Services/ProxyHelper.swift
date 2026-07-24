import Foundation
import AppKit
import CoreImage
import Darwin

enum ProxyHelper {
    static func generatePAC(
        httpProxy: String,
        socksProxy: String = "127.0.0.1:1080",
        allowList: [String] = [],
        denyList: [String] = []
    ) -> String {
        let allowJS = jsStringArray(allowList)
        let denyJS = jsStringArray(denyList)
        return """
        function hostMatchesList(host, list) {
            host = (host || "").toLowerCase();
            for (var i = 0; i < list.length; i++) {
                var d = (list[i] || "").toLowerCase();
                if (!d) continue;
                // Exact host or IP match.
                if (host === d) return true;
                // Domain suffix match (example.com matches a.example.com).
                if (host.endsWith("." + d)) return true;
            }
            return false;
        }

        function isIPLiteral(host) {
            if (!host) return false;
            // IPv4 digits-only check (avoid JS regex escapes inside Swift string)
            var parts = host.split(".");
            if (parts.length === 4) {
                var ok = true;
                for (var i = 0; i < 4; i++) {
                    var p = parts[i];
                    if (!p || p.length > 3) { ok = false; break; }
                    for (var j = 0; j < p.length; j++) {
                        var c = p.charCodeAt(j);
                        if (c < 48 || c > 57) { ok = false; break; }
                    }
                    if (!ok) break;
                    if (parseInt(p, 10) > 255) { ok = false; break; }
                }
                if (ok) return true;
            }
            // rough IPv6
            if (host.indexOf(":") >= 0) return true;
            return false;
        }

        function FindProxyForURL(url, host) {
            if (!host) return "DIRECT";
            host = host.toLowerCase();

            // Explicit deny / bypass list always wins (domains + IPs).
            var denyList = \(denyJS);
            if (hostMatchesList(host, denyList)) {
                return "DIRECT";
            }

            // Local / private ranges stay direct (skip dnsResolve for IP literals).
            if (isPlainHostName(host) || shExpMatch(host, "*.local")) {
                return "DIRECT";
            }
            if (!isIPLiteral(host)) {
                try {
                    var resolved = dnsResolve(host);
                    if (resolved && (
                        isInNet(resolved, "10.0.0.0", "255.0.0.0") ||
                        isInNet(resolved, "172.16.0.0", "255.240.0.0") ||
                        isInNet(resolved, "192.168.0.0", "255.255.0.0") ||
                        isInNet(resolved, "127.0.0.0", "255.0.0.0"))) {
                        return "DIRECT";
                    }
                } catch (e) {}
            } else {
                if (isInNet(host, "10.0.0.0", "255.0.0.0") ||
                    isInNet(host, "172.16.0.0", "255.240.0.0") ||
                    isInNet(host, "192.168.0.0", "255.255.0.0") ||
                    isInNet(host, "127.0.0.0", "255.0.0.0")) {
                    return "DIRECT";
                }
            }

            var allowList = \(allowJS);
            if (allowList.length > 0) {
                // Only listed domains/IPs enter OpenZweb local proxy.
                if (!hostMatchesList(host, allowList)) {
                    return "DIRECT";
                }
            }

            return "SOCKS5 \(socksProxy); SOCKS \(socksProxy); PROXY \(httpProxy); DIRECT";
        }
        """
    }

    private static func jsStringArray(_ items: [String]) -> String {
        let escaped = items.map { item -> String in
            let e = item
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(e)\""
        }
        return "[" + escaped.joined(separator: ", ") + "]"
    }

    static func savePAC(
        httpProxy: String,
        socksProxy: String = "127.0.0.1:1080",
        allowList: [String] = [],
        denyList: [String] = []
    ) throws -> URL {
        let dir = CoreBinaryManager.supportDirectory
        let url = dir.appendingPathComponent("openzweb.pac")
        try generatePAC(
            httpProxy: httpProxy,
            socksProxy: socksProxy,
            allowList: allowList,
            denyList: denyList
        ).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Primary non-loopback IPv4 for LAN sharing.
    static func primaryLANAddress() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        var candidates: [String] = []
        while let p = ptr {
            let name = String(cString: p.pointee.ifa_name)
            if name.hasPrefix("en") || name.hasPrefix("bridge") || name.hasPrefix("wlan") {
                if p.pointee.ifa_addr.pointee.sa_family == UInt8(AF_INET) {
                    var addr = p.pointee.ifa_addr.pointee
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(&addr, socklen_t(p.pointee.ifa_addr.pointee.sa_len),
                                &hostname, socklen_t(hostname.count),
                                nil, 0, NI_NUMERICHOST)
                    let ip = String(cString: hostname)
                    if ip != "127.0.0.1", !ip.hasPrefix("169.254.") {
                        candidates.append(ip)
                    }
                }
            }
            ptr = p.pointee.ifa_next
        }
        return candidates.first
    }

    /// Rewrite 127.0.0.1/localhost binds to 0.0.0.0 for LAN share.
    static func lanBind(from bind: String) -> String {
        guard let ep = SystemProxyManager.Endpoint.parse(bind) else { return bind }
        return "0.0.0.0:\(ep.port)"
    }

    static func hostPort(from bind: String, lanHost: String?) -> (host: String, port: Int)? {
        guard let ep = SystemProxyManager.Endpoint.parse(bind) else { return nil }
        let host: String
        if ep.host == "0.0.0.0" || ep.host == "::" {
            host = lanHost ?? "127.0.0.1"
        } else if ep.host == "127.0.0.1" || ep.host == "localhost" {
            host = lanHost ?? ep.host
        } else {
            host = ep.host
        }
        return (host, ep.port)
    }

    /// QR payload for other devices (Surge/Clash-friendly SOCKS URI + plain hint).
    static func lanSharePayload(socksBind: String, httpBind: String) -> String {
        let lan = primaryLANAddress() ?? "127.0.0.1"
        let socks = hostPort(from: socksBind, lanHost: lan)
        let http = hostPort(from: httpBind, lanHost: lan)
        var lines: [String] = ["OpenZweb LAN Proxy"]
        if let socks {
            lines.append("SOCKS5 \(socks.host):\(socks.port)")
            lines.append("socks5://\(socks.host):\(socks.port)")
        }
        if let http {
            lines.append("HTTP \(http.host):\(http.port)")
            lines.append("http://\(http.host):\(http.port)")
        }
        lines.append("DNS: prefer remote / socks5h when available")
        return lines.joined(separator: "\n")
    }

    static func qrImage(from string: String, dimension: CGFloat = 220) -> NSImage? {
        guard let data = string.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scale = dimension / output.extent.width
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
