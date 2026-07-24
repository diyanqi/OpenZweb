import Foundation

/// Snapshot / apply / restore macOS system HTTP(S)/SOCKS proxies via `networksetup`.
enum SystemProxyManager {
    private static let snapshotKey = "openzweb.systemProxy.snapshot"
    private static let appliedKey = "openzweb.systemProxy.applied"

    struct Endpoint: Equatable {
        var host: String
        var port: Int

        static func parse(_ bind: String) -> Endpoint? {
            let parts = bind.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count >= 2, let port = Int(parts.last!) else { return nil }
            let host = parts.dropLast().joined(separator: ":")
            let h = host.isEmpty || host == "0.0.0.0" || host == "::" ? "127.0.0.1" : host
            return Endpoint(host: h, port: port)
        }
    }

    struct ServiceState: Codable, Equatable {
        var service: String
        var webEnabled: Bool
        var webHost: String
        var webPort: Int
        var secureEnabled: Bool
        var secureHost: String
        var securePort: Int
        var socksEnabled: Bool
        var socksHost: String
        var socksPort: Int
        var bypassDomains: [String]
    }

    struct Snapshot: Codable, Equatable {
        var services: [ServiceState]
        var savedAt: Date
    }

    // MARK: - Detect non-empty system proxy (no process scanning)

    struct Conflict: Equatable {
        var title: String
        var detail: String
    }

    /// Returns a conflict if the **effective** system proxy is not empty,
    /// excluding OpenZweb's own leftover local proxy (127.0.0.1:http/socks).
    /// Uses `scutil --proxy` first (what apps actually see), then networksetup as fallback.
    /// Does not inspect running apps or mention third-party product names.
    static func detectActiveSystemProxy(
        httpBind: String? = nil,
        socksBind: String? = nil
    ) -> Conflict? {
        let ours = ownedEndpoints(httpBind: httpBind, socksBind: socksBind)
        if let conflict = detectViaScutil(owned: ours) {
            return conflict
        }
        // Fallback: per-service networksetup (read-only, never admin).
        if let services = try? listNetworkServices(readOnly: true) {
            for service in services {
                if let state = try? readState(service: service, readOnly: true) {
                    if foreignProxyEnabled(state: state, owned: ours) {
                        return Self.systemProxyConflictMessage
                    }
                }
                if isAutoProxyEnabled(service: service) {
                    return Self.systemProxyConflictMessage
                }
            }
        }
        return nil
    }

    /// Human summary for logs / UI even when empty.
    static func proxyCheckSummary(httpBind: String? = nil, socksBind: String? = nil) -> String {
        if let conflict = detectActiveSystemProxy(httpBind: httpBind, socksBind: socksBind) {
            return L10n.format("proxy.check_fail", conflict.title)
        }
        if isLikelyOpenZwebResidualProxy(httpBind: httpBind, socksBind: socksBind) {
            return L10n.t("proxy.check_pass_self")
        }
        return L10n.t("proxy.check_pass_empty")
    }

    /// True when system proxy is on but only points at OpenZweb local binds.
    static func isLikelyOpenZwebResidualProxy(httpBind: String? = nil, socksBind: String? = nil) -> Bool {
        let ours = ownedEndpoints(httpBind: httpBind, socksBind: socksBind)
        guard !ours.isEmpty else { return false }
        // Prefer scutil snapshot
        if let text = scutilProxyText() {
            let anyOn =
                scutilFlagEnabled(text, key: "HTTPEnable")
                || scutilFlagEnabled(text, key: "HTTPSEnable")
                || scutilFlagEnabled(text, key: "SOCKSEnable")
            if !anyOn { return false }
            if scutilFlagEnabled(text, key: "ProxyAutoConfigEnable")
                || scutilFlagEnabled(text, key: "ProxyAutoDiscoveryEnable") {
                return false
            }
            return !foreignProxyInScutil(text, owned: ours)
        }
        return UserDefaults.standard.bool(forKey: appliedKey)
    }

    private static var systemProxyConflictMessage: Conflict {
        Conflict(
            title: L10n.t("proxy.conflict_title"),
            detail: L10n.t("proxy.conflict_detail")
        )
    }

    /// Local endpoints we manage: configured binds + common defaults.
    private static func ownedEndpoints(httpBind: String?, socksBind: String?) -> Set<String> {
        var set = Set<String>()
        func add(_ bind: String?) {
            guard let ep = bind.flatMap(Endpoint.parse) else { return }
            for host in ["127.0.0.1", "localhost", "::1"] {
                set.insert("\(host):\(ep.port)")
            }
        }
        add(httpBind)
        add(socksBind)
        // Defaults used by OpenZweb
        for port in [1080, 1081] {
            for host in ["127.0.0.1", "localhost", "::1"] {
                set.insert("\(host):\(port)")
            }
        }
        return set
    }

    private static func endpointKey(host: String, port: Int) -> String {
        var h = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if h.isEmpty || h == "0.0.0.0" || h == "*" || h == "::" { h = "127.0.0.1" }
        if h == "localhost" || h == "::1" { h = "127.0.0.1" }
        return "\(h):\(port)"
    }

    private static func isOwned(_ host: String, _ port: Int, owned: Set<String>) -> Bool {
        owned.contains(endpointKey(host: host, port: port))
    }

    private static func foreignProxyEnabled(state: ServiceState, owned: Set<String>) -> Bool {
        if state.webEnabled, !isOwned(state.webHost, state.webPort, owned: owned) { return true }
        if state.secureEnabled, !isOwned(state.secureHost, state.securePort, owned: owned) { return true }
        if state.socksEnabled, !isOwned(state.socksHost, state.socksPort, owned: owned) { return true }
        return false
    }

    private static func scutilProxyText() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/scutil")
        process.arguments = ["--proxy"]
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do {
            try process.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            _ = err.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    private static func scutilString(_ text: String, key: String) -> String? {
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(key) || trimmed.contains("\(key) ") else { continue }
            // "HTTPProxy : 127.0.0.1"
            if let r = trimmed.range(of: #":\s*(.+)$"#, options: .regularExpression) {
                var v = String(trimmed[r])
                if let colon = v.firstIndex(of: ":") {
                    v = String(v[v.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                }
                return v
            }
        }
        return nil
    }

    private static func scutilInt(_ text: String, key: String) -> Int? {
        guard let s = scutilString(text, key: key) else { return nil }
        return Int(s.filter(\.isNumber)) ?? Int(s)
    }

    private static func foreignProxyInScutil(_ text: String, owned: Set<String>) -> Bool {
        if scutilFlagEnabled(text, key: "HTTPEnable") {
            let host = scutilString(text, key: "HTTPProxy") ?? ""
            let port = scutilInt(text, key: "HTTPPort") ?? 0
            if !isOwned(host, port, owned: owned) { return true }
        }
        if scutilFlagEnabled(text, key: "HTTPSEnable") {
            let host = scutilString(text, key: "HTTPSProxy") ?? ""
            let port = scutilInt(text, key: "HTTPSPort") ?? 0
            if !isOwned(host, port, owned: owned) { return true }
        }
        if scutilFlagEnabled(text, key: "SOCKSEnable") {
            let host = scutilString(text, key: "SOCKSProxy") ?? ""
            let port = scutilInt(text, key: "SOCKSPort") ?? 0
            if !isOwned(host, port, owned: owned) { return true }
        }
        return false
    }

    private static func detectViaScutil(owned: Set<String>) -> Conflict? {
        guard let text = scutilProxyText() else { return nil }
        // PAC / WPAD from third parties always conflict.
        if scutilFlagEnabled(text, key: "ProxyAutoConfigEnable")
            || scutilFlagEnabled(text, key: "ProxyAutoDiscoveryEnable") {
            return Self.systemProxyConflictMessage
        }
        let anyManual =
            scutilFlagEnabled(text, key: "HTTPEnable")
            || scutilFlagEnabled(text, key: "HTTPSEnable")
            || scutilFlagEnabled(text, key: "SOCKSEnable")
        guard anyManual else { return nil }
        if foreignProxyInScutil(text, owned: owned) {
            return Self.systemProxyConflictMessage
        }
        // Only OpenZweb residual — not a conflict.
        return nil
    }

    private static func scutilFlagEnabled(_ text: String, key: String) -> Bool {
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.contains(key) else { continue }
            // formats: "HTTPEnable : 1" or "HTTPEnable : 0"
            if let r = trimmed.range(of: #":\s*(\d+)"#, options: .regularExpression) {
                let num = trimmed[r].filter(\.isNumber)
                return num == "1"
            }
            if trimmed.lowercased().contains(": true") { return true }
        }
        return false
    }

    private static func isAutoProxyEnabled(service: String) -> Bool {
        guard let text = try? run(["-getautoproxyurl", service], readOnly: true) else { return false }
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard parts.count == 2 else { continue }
            if parts[0].lowercased() == "enabled" {
                return parts[1].lowercased().hasPrefix("y")
            }
        }
        return false
    }

    // MARK: - Apply / restore

    private static let dnsSnapshotKey = "openzweb.systemDNS.snapshot"
    private static let dnsAppliedKey = "openzweb.systemDNS.applied"

    struct DNSSnapshot: Codable {
        var services: [String: [String]]
    }

    /// Apply proxy + optional DNS in **one** background-friendly batch (single admin prompt max).
    /// Must NOT be called on the main thread for long; prefer `Task.detached`.
    static func applyProxyAndDNS(
        httpBind: String,
        socksBind: String,
        dnsServers: [String]?,
        manageProxy: Bool,
        manageDNS: Bool,
        extraBypassDomains: [String] = []
    ) throws {
        guard manageProxy || manageDNS else { return }
        guard let http = Endpoint.parse(httpBind), let socks = Endpoint.parse(socksBind) else {
            throw ProxyError.invalidBind
        }

        // Snapshot current state (read-only, no admin).
        let services = try listNetworkServices(readOnly: true)
        if manageProxy {
            var before: [ServiceState] = []
            for service in services {
                if let state = try? readState(service: service, readOnly: true) {
                    before.append(state)
                } else {
                    before.append(ServiceState(
                        service: service,
                        webEnabled: false, webHost: "", webPort: 0,
                        secureEnabled: false, secureHost: "", securePort: 0,
                        socksEnabled: false, socksHost: "", socksPort: 0,
                        bypassDomains: []
                    ))
                }
            }
            persistSnapshot(Snapshot(services: before, savedAt: Date()))
        }
        if manageDNS, let dnsServers, !dnsServers.isEmpty {
            var map: [String: [String]] = [:]
            for service in services {
                map[service] = (try? readDNS(service: service)) ?? []
            }
            if let data = try? JSONEncoder().encode(DNSSnapshot(services: map)) {
                UserDefaults.standard.set(data, forKey: dnsSnapshotKey)
            }
        }

        var scriptLines: [String] = ["set -e"]
        var bypassParts = ["127.0.0.1", "localhost", "*.local", "vpn.zju.edu.cn", "zjuam.zju.edu.cn"]
        for d in extraBypassDomains where !d.isEmpty {
            if !bypassParts.contains(d) { bypassParts.append(d) }
        }
        let bypass = bypassParts.joined(separator: " ")
        for service in services {
            let s = shellQuote(service)
            if manageProxy {
                scriptLines += [
                    "/usr/sbin/networksetup -setwebproxy \(s) \(shellQuote(http.host)) \(http.port)",
                    "/usr/sbin/networksetup -setwebproxystate \(s) on",
                    "/usr/sbin/networksetup -setsecurewebproxy \(s) \(shellQuote(http.host)) \(http.port)",
                    "/usr/sbin/networksetup -setsecurewebproxystate \(s) on",
                    "/usr/sbin/networksetup -setsocksfirewallproxy \(s) \(shellQuote(socks.host)) \(socks.port)",
                    "/usr/sbin/networksetup -setsocksfirewallproxystate \(s) on",
                    "/usr/sbin/networksetup -setproxybypassdomains \(s) \(bypass)"
                ]
            }
            if manageDNS, let dnsServers, !dnsServers.isEmpty {
                let dnsArgs = dnsServers.map(shellQuote).joined(separator: " ")
                scriptLines.append("/usr/sbin/networksetup -setdnsservers \(s) \(dnsArgs)")
            }
        }

        try runBatchScript(scriptLines.joined(separator: "\n"))
        if manageProxy { UserDefaults.standard.set(true, forKey: appliedKey) }
        if manageDNS { UserDefaults.standard.set(true, forKey: dnsAppliedKey) }
    }

    static func restoreAllIfNeeded() {
        let needProxy = UserDefaults.standard.bool(forKey: appliedKey)
        let needDNS = UserDefaults.standard.bool(forKey: dnsAppliedKey)
        guard needProxy || needDNS else { return }

        var scriptLines: [String] = ["set -e"]

        if needProxy {
            if let data = UserDefaults.standard.data(forKey: snapshotKey),
               let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) {
                for state in snapshot.services {
                    let s = shellQuote(state.service)
                    if state.webEnabled {
                        scriptLines += [
                            "/usr/sbin/networksetup -setwebproxy \(s) \(shellQuote(state.webHost)) \(state.webPort)",
                            "/usr/sbin/networksetup -setwebproxystate \(s) on"
                        ]
                    } else {
                        scriptLines.append("/usr/sbin/networksetup -setwebproxystate \(s) off")
                    }
                    if state.secureEnabled {
                        scriptLines += [
                            "/usr/sbin/networksetup -setsecurewebproxy \(s) \(shellQuote(state.secureHost)) \(state.securePort)",
                            "/usr/sbin/networksetup -setsecurewebproxystate \(s) on"
                        ]
                    } else {
                        scriptLines.append("/usr/sbin/networksetup -setsecurewebproxystate \(s) off")
                    }
                    if state.socksEnabled {
                        scriptLines += [
                            "/usr/sbin/networksetup -setsocksfirewallproxy \(s) \(shellQuote(state.socksHost)) \(state.socksPort)",
                            "/usr/sbin/networksetup -setsocksfirewallproxystate \(s) on"
                        ]
                    } else {
                        scriptLines.append("/usr/sbin/networksetup -setsocksfirewallproxystate \(s) off")
                    }
                    if !state.bypassDomains.isEmpty {
                        let d = state.bypassDomains.map(shellQuote).joined(separator: " ")
                        scriptLines.append("/usr/sbin/networksetup -setproxybypassdomains \(s) \(d)")
                    }
                }
            } else if let services = try? listNetworkServices(readOnly: true) {
                for service in services {
                    let s = shellQuote(service)
                    scriptLines += [
                        "/usr/sbin/networksetup -setwebproxystate \(s) off",
                        "/usr/sbin/networksetup -setsecurewebproxystate \(s) off",
                        "/usr/sbin/networksetup -setsocksfirewallproxystate \(s) off"
                    ]
                }
            }
        }

        if needDNS {
            if let data = UserDefaults.standard.data(forKey: dnsSnapshotKey),
               let snap = try? JSONDecoder().decode(DNSSnapshot.self, from: data) {
                for (service, servers) in snap.services {
                    let s = shellQuote(service)
                    if servers.isEmpty {
                        scriptLines.append("/usr/sbin/networksetup -setdnsservers \(s) Empty")
                    } else {
                        let d = servers.map(shellQuote).joined(separator: " ")
                        scriptLines.append("/usr/sbin/networksetup -setdnsservers \(s) \(d)")
                    }
                }
            } else if let services = try? listNetworkServices(readOnly: true) {
                for service in services {
                    scriptLines.append("/usr/sbin/networksetup -setdnsservers \(shellQuote(service)) Empty")
                }
            }
        }

        try? runBatchScript(scriptLines.joined(separator: "\n"))
        UserDefaults.standard.set(false, forKey: appliedKey)
        UserDefaults.standard.set(false, forKey: dnsAppliedKey)
        UserDefaults.standard.removeObject(forKey: snapshotKey)
        UserDefaults.standard.removeObject(forKey: dnsSnapshotKey)
    }

    // Back-compat wrappers
    @discardableResult
    static func applyOpenZwebProxy(httpBind: String, socksBind: String) throws -> Snapshot {
        try applyProxyAndDNS(
            httpBind: httpBind,
            socksBind: socksBind,
            dnsServers: nil,
            manageProxy: true,
            manageDNS: false
        )
        if let data = UserDefaults.standard.data(forKey: snapshotKey),
           let snap = try? JSONDecoder().decode(Snapshot.self, from: data) {
            return snap
        }
        return Snapshot(services: [], savedAt: Date())
    }

    static func applyDNS(servers: [String]) throws {
        try applyProxyAndDNS(
            httpBind: "127.0.0.1:1081",
            socksBind: "127.0.0.1:1080",
            dnsServers: servers,
            manageProxy: false,
            manageDNS: true
        )
    }

    static func restoreIfNeeded() { restoreAllIfNeeded() }
    static func restoreFromSnapshot() { restoreAllIfNeeded() }
    static func restoreDNSIfNeeded() { restoreAllIfNeeded() }

    private static func readDNS(service: String) throws -> [String] {
        let text = try run(["-getdnsservers", service], readOnly: true)
        let lower = text.lowercased()
        if lower.contains("aren't any") || lower.contains("there aren") {
            return []
        }
        return text
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.lowercased().contains("dns") }
    }

    private static func persistSnapshot(_ snapshot: Snapshot) {
        if let data = try? JSONEncoder().encode(snapshot) {
            UserDefaults.standard.set(data, forKey: snapshotKey)
        }
    }

    // MARK: - networksetup helpers

    static func listNetworkServices(readOnly: Bool = false) throws -> [String] {
        let out = try run(["-listallnetworkservices"], readOnly: readOnly)
        return out
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("An asterisk") && !$0.hasPrefix("*") }
    }

    private static func readState(service: String, readOnly: Bool = false) throws -> ServiceState {
        let web = try parseProxyBlock(run(["-getwebproxy", service], readOnly: readOnly))
        let secure = try parseProxyBlock(run(["-getsecurewebproxy", service], readOnly: readOnly))
        let socks = try parseProxyBlock(run(["-getsocksfirewallproxy", service], readOnly: readOnly))
        let bypassRaw = (try? run(["-getproxybypassdomains", service], readOnly: readOnly)) ?? ""
        let bypass = bypassRaw
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.lowercased().contains("there aren't any") }
        return ServiceState(
            service: service,
            webEnabled: web.enabled,
            webHost: web.host,
            webPort: web.port,
            secureEnabled: secure.enabled,
            secureHost: secure.host,
            securePort: secure.port,
            socksEnabled: socks.enabled,
            socksHost: socks.host,
            socksPort: socks.port,
            bypassDomains: bypass
        )
    }

    private struct ParsedProxy {
        var enabled: Bool
        var host: String
        var port: Int
    }

    private static func parseProxyBlock(_ text: String) throws -> ParsedProxy {
        var enabled = false
        var host = ""
        var port = 0
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard parts.count == 2 else { continue }
            let key = parts[0].lowercased()
            let value = parts[1]
            if key == "enabled" {
                enabled = value.lowercased().hasPrefix("y")
            } else if key == "server" {
                host = value
            } else if key == "port" {
                port = Int(value) ?? 0
            }
        }
        return ParsedProxy(enabled: enabled, host: host, port: port)
    }

    /// Run many networksetup commands in one process; elevates only if needed (one prompt).
    private static func runBatchScript(_ script: String) throws {
        // Try without admin first.
        if (try? runShell(script, elevate: false)) != nil { return }
        try runShell(script, elevate: true)
    }

    @discardableResult
    private static func runShell(_ script: String, elevate: Bool) throws -> String {
        if elevate {
            // Write script to temp file to avoid huge AppleScript escaping issues.
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("openzweb-netsetup-\(UUID().uuidString).sh")
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            defer { try? FileManager.default.removeItem(at: url) }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = [
                "-e",
                "do shell script \(appleScriptString("/bin/bash \(shellQuote(url.path))")) with administrator privileges"
            ]
            return try finish(process)
        } else {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = ["-c", script]
            return try finish(process)
        }
    }

    @discardableResult
    private static func run(_ args: [String], readOnly: Bool = false) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        process.arguments = args
        do {
            return try finish(process)
        } catch {
            if readOnly { throw error }
            // Single elevated networksetup as fallback
            let quoted = args.map(shellQuote).joined(separator: " ")
            let process2 = Process()
            process2.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process2.arguments = [
                "-e",
                "do shell script \(appleScriptString("/usr/sbin/networksetup \(quoted)")) with administrator privileges"
            ]
            return try finish(process2)
        }
    }

    private static func finish(_ process: Process) throws -> String {
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        // Read while waiting to avoid pipe-buffer deadlock.
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let msg = String(data: errData, encoding: .utf8) ?? "networksetup failed"
            throw ProxyError.commandFailed(msg.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return String(data: outData, encoding: .utf8) ?? ""
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func appleScriptString(_ s: String) -> String {
        "\"" + s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

}

enum ProxyError: LocalizedError {
    case invalidBind
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidBind:
            return "代理绑定地址无效"
        case .commandFailed(let msg):
            return "修改系统代理失败：\(msg)"
        }
    }
}
