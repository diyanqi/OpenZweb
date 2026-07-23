import Foundation
import Combine
import Darwin

/// Samples interface counters and optional public-IP / reachability checks.
@MainActor
final class NetworkMonitor: ObservableObject {
    struct Sample: Identifiable, Equatable {
        let id = UUID()
        let date: Date
        let downBps: Double
        let upBps: Double
    }

    @Published private(set) var samples: [Sample] = []
    @Published private(set) var downBps: Double = 0
    @Published private(set) var upBps: Double = 0
    @Published private(set) var publicIP: String?
    @Published private(set) var campusIP: String?
    @Published private(set) var campusReachable: Bool?
    @Published private(set) var lastCheckMessage: String = "尚未检测"
    @Published private(set) var isChecking = false

    private var task: Task<Void, Never>?
    private var lastIn: UInt64 = 0
    private var lastOut: UInt64 = 0
    private var lastStamp: Date?
    private let maxSamples = 60

    func start() {
        guard task == nil else { return }
        task = Task.detached(priority: .utility) { [weak self] in
            var lastIn: UInt64 = 0
            var lastOut: UInt64 = 0
            var lastStamp: Date?
            let first = Self.readBytes()
            lastIn = first.0
            lastOut = first.1
            lastStamp = Date()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { break }
                let (inn, out) = Self.readBytes()
                let now = Date()
                let prev = lastStamp ?? now
                let dt = now.timeIntervalSince(prev)
                let dIn = inn >= lastIn ? inn - lastIn : 0
                let dOut = out >= lastOut ? out - lastOut : 0
                lastIn = inn
                lastOut = out
                lastStamp = now
                guard dt > 0.2 else { continue }
                let down = Double(dIn) / dt
                let up = Double(dOut) / dt
                guard let monitor = self else { return }
                await MainActor.run {
                    monitor.downBps = down
                    monitor.upBps = up
                    monitor.samples.append(Sample(date: now, downBps: down, upBps: up))
                    if monitor.samples.count > monitor.maxSamples {
                        monitor.samples.removeFirst(monitor.samples.count - monitor.maxSamples)
                    }
                }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        samples = []
        downBps = 0
        upBps = 0
    }

    func refreshIP(httpProxy: String?, socksProxy: String?) async {
        isChecking = true
        defer { isChecking = false }
        publicIP = await Self.fetchText(
            url: URL(string: "https://api.ipify.org")!,
            httpProxy: httpProxy,
            socksProxy: socksProxy
        )
        // Lightweight campus probe (CC98)
        let campus = await Self.fetchStatus(
            url: URL(string: "https://www.cc98.org")!,
            httpProxy: httpProxy,
            socksProxy: socksProxy
        )
        campusReachable = campus
        if let publicIP {
            lastCheckMessage = campus == true
                ? "公网 \(publicIP) · 校内可达"
                : "公网 \(publicIP) · 校内探测失败"
        } else {
            lastCheckMessage = campus == true ? "校内可达" : "网络探测失败"
        }
    }

    // MARK: - Counters

    nonisolated private static func readBytes() -> (UInt64, UInt64) {
        // netstat -ib: Name Mtu Network Address Ipkts Ierrs Ibytes Opkts Oerrs Obytes ...
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/netstat")
        p.arguments = ["-ib"]
        let outPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = Pipe()
        do {
            try p.run()
            p.waitUntilExit()
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            guard let text = String(data: data, encoding: .utf8) else { return (0, 0) }
            var inn: UInt64 = 0
            var out: UInt64 = 0
            for line in text.split(separator: "\n").dropFirst() {
                let cols = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init).filter { !$0.isEmpty }
                guard cols.count >= 10 else { continue }
                let name = cols[0]
                if name == "lo0" || name.hasSuffix("*") { continue }
                // Ibytes / Obytes positions vary slightly; typically indices 6 and 9 on macOS
                if let ib = UInt64(cols[6]), let ob = UInt64(cols[9]) {
                    inn += ib
                    out += ob
                }
            }
            return (inn, out)
        } catch {
            return (0, 0)
        }
    }

    nonisolated private static func fetchText(url: URL, httpProxy: String?, socksProxy: String?) async -> String? {
        // Prefer curl + socks5h so DNS goes through the tunnel (matches terminal behaviour).
        if let socksProxy {
            let hostPort = socksProxy.replacingOccurrences(of: "0.0.0.0", with: "127.0.0.1")
            if let text = await curlProxy(url: url.absoluteString, socks: hostPort) {
                return text
            }
        }
        if let httpProxy {
            let hostPort = httpProxy.replacingOccurrences(of: "0.0.0.0", with: "127.0.0.1")
            if let text = await curlProxy(url: url.absoluteString, http: hostPort) {
                return text
            }
        }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return nil
            }
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }

    nonisolated private static func fetchStatus(url: URL, httpProxy: String?, socksProxy: String?) async -> Bool {
        if let socksProxy {
            let hostPort = socksProxy.replacingOccurrences(of: "0.0.0.0", with: "127.0.0.1")
            return await curlProxyOK(url: url.absoluteString, socks: hostPort)
        }
        if let httpProxy {
            let hostPort = httpProxy.replacingOccurrences(of: "0.0.0.0", with: "127.0.0.1")
            return await curlProxyOK(url: url.absoluteString, http: hostPort)
        }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.httpMethod = "HEAD"
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse).map { (200...499).contains($0.statusCode) } ?? false
        } catch {
            return false
        }
    }

    nonisolated private static func curlProxy(url: String, socks: String? = nil, http: String? = nil) async -> String? {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
                var args = ["-fsS", "--max-time", "8"]
                if let socks { args += ["-x", "socks5h://\(socks)"] }
                else if let http { args += ["-x", "http://\(http)"] }
                args.append(url)
                p.arguments = args
                let out = Pipe()
                p.standardOutput = out
                p.standardError = Pipe()
                do {
                    try p.run()
                    p.waitUntilExit()
                    let data = out.fileHandleForReading.readDataToEndOfFile()
                    let text = String(data: data, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    cont.resume(returning: (p.terminationStatus == 0) ? text : nil)
                } catch {
                    cont.resume(returning: nil)
                }
            }
        }
    }

    nonisolated private static func curlProxyOK(url: String, socks: String? = nil, http: String? = nil) async -> Bool {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
                var args = ["-fsS", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "8"]
                if let socks { args += ["-x", "socks5h://\(socks)"] }
                else if let http { args += ["-x", "http://\(http)"] }
                args.append(url)
                p.arguments = args
                let out = Pipe()
                p.standardOutput = out
                p.standardError = Pipe()
                do {
                    try p.run()
                    p.waitUntilExit()
                    let code = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    cont.resume(returning: p.terminationStatus == 0 || (Int(code).map { $0 > 0 } ?? false))
                } catch {
                    cont.resume(returning: false)
                }
            }
        }
    }

    nonisolated static func formatRate(_ bps: Double) -> String {
        if bps < 1024 { return String(format: "%.0f B/s", bps) }
        if bps < 1024 * 1024 { return String(format: "%.1f KB/s", bps / 1024) }
        return String(format: "%.2f MB/s", bps / 1024 / 1024)
    }
}
