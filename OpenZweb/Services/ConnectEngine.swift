import Foundation
import AppKit
import Combine
import Darwin

@MainActor
final class ConnectEngine: ObservableObject {
    @Published private(set) var phase: ConnectionPhase = .idle
    @Published private(set) var logs: [String] = []
    @Published private(set) var captchaImage: NSImage?
    @Published var captchaCode: String = ""
    @Published var smsCode: String = ""
    /// Soft SMS validation error (wrong code); sheet stays open for retry when possible.
    @Published private(set) var smsError: String?
    /// Bumped to trigger OTP shake animation.
    @Published private(set) var smsShakeToken: Int = 0
    /// True while waiting for SMS verification result (digits stay, input locked).
    @Published private(set) var isSubmittingSMS = false
    @Published private(set) var lastError: String?
    /// One-shot failure dialog (no auto-retry). Cleared when user dismisses.
    @Published var failureDialogMessage: String?
    @Published private(set) var coreBinaryPath: String?
    /// Warning or install hint for the protocol engine (arch mismatch / missing).
    @Published private(set) var coreBinaryNote: String?
    @Published private(set) var isDownloadingCore = false
    @Published private(set) var connectedSince: Date?
    @Published private(set) var activeMode: ConnectionMode = .proxy

    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var fifoWriteHandle: FileHandle?
    private var outputBuffer = ""
    private var reconnectTask: Task<Void, Never>?
    private var captchaPollTask: Task<Void, Never>?
    private var proxyProbeTask: Task<Void, Never>?
    /// Password step OK; tunnel may still need SMS / captcha.
    private var passwordAuthSucceeded = false
    private var lastPassword: String = ""
    private var lastSettings: AppSettings?
    private var runtimeConfigURL: URL?
    private var elevated = false
    /// True only after real aTrust login / proxy listeners are up (not early init logs).
    private var didAuthenticate = false
    private var openedCaptchaURLs = Set<String>()
    /// Browser captcha page served by zju-connect (aTrust click captcha).
    @Published private(set) var captchaServerURL: URL?
    /// System proxy was non-empty when user tried to connect.
    @Published private(set) var proxyConflict: SystemProxyManager.Conflict?
    @Published private(set) var systemProxyManaged = false
    /// Skip the next connect-time system-proxy check exactly once (user confirmed).
    private var skipProxyCheckOnce = false
    /// Keep SMS OTP sheet visible across soft failures / process restarts.
    @Published private(set) var holdSMSSheet = false
    /// Secondary SMS prompt: show EZ4Connect-style skip checkbox.
    @Published private(set) var smsAllowsSkipSecondary = false
    /// User wants $ prefix on this SMS submit.
    @Published var skipSecondaryAuth = false
    /// Code to auto-submit when the engine re-prompts for SMS after a retry relaunch.
    private var pendingSMSCode: String?
    /// True while we are relaunching the engine solely to re-enter SMS.
    private var smsRetryRelaunch = false
    /// Captcha already completed in this connect attempt; ignore residual captcha files/logs.
    private var captchaSatisfied = false
    /// Last captcha server URL we already switched UI to (avoid re-entering waitingCaptcha).
    private var lastCaptchaServerURLString: String?

    init() {
        refreshCoreBinary()
        // If previous session crashed while owning system proxy, restore snapshot.
        Task.detached(priority: .utility) {
            SystemProxyManager.restoreAllIfNeeded()
        }
    }

    /// Re-detect system proxy. If clear (or only OpenZweb residual), resume connect.
    func recheckProxyConflictAndContinue() {
        let http = lastSettings?.httpBind
        let socks = lastSettings?.socksBind
        let summary = SystemProxyManager.proxyCheckSummary(httpBind: http, socksBind: socks)
        appendLog("[OpenZweb] " + L10n.format("log.recheck", summary))
        if let conflict = SystemProxyManager.detectActiveSystemProxy(httpBind: http, socksBind: socks) {
            // Still conflict — keep dialog open with refreshed message.
            proxyConflict = conflict
            return
        }
        proxyConflict = nil
        guard let settings = lastSettings else { return }
        // Resume the connect that was interrupted by the warning.
        connect(settings: settings, password: lastPassword)
    }

    /// User chose to proceed even with foreign system proxy.
    func continueDespiteProxyConflict() {
        proxyConflict = nil
        skipProxyCheckOnce = true
        appendLog("[OpenZweb] " + L10n.t("log.continue_anyway"))
        guard let settings = lastSettings else { return }
        connect(settings: settings, password: lastPassword)
    }

    /// Clear alert without connecting (e.g. user dismissed).
    func dismissProxyConflictWarning() {
        proxyConflict = nil
    }

    func dismissFailureDialog() {
        failureDialogMessage = nil
    }

    /// Present a failure dialog once and cancel any pending reconnect.
    private func presentFailure(_ message: String, log: Bool = true) {
        reconnectTask?.cancel()
        reconnectTask = nil
        lastError = message
        failureDialogMessage = message
        if case .failed = phase {
            // keep
        } else {
            phase = .failed(message)
        }
        if log {
            appendLog("[OpenZweb] \(message)")
        }
    }

    func refreshCoreBinary() {
        if let info = CoreBinaryManager.resolveBinary() {
            coreBinaryPath = info.url.path
            if info.isNative {
                coreBinaryNote = nil
            } else {
                coreBinaryNote = CoreBinaryManager.diagnosisMessage()
            }
        } else {
            coreBinaryPath = nil
            coreBinaryNote = CoreBinaryManager.diagnosisMessage()
        }
    }

    func downloadCore() async {
        isDownloadingCore = true
        defer { isDownloadingCore = false }
        do {
            let url = try await CoreBinaryManager.downloadLatest()
            refreshCoreBinary()
            appendLog("[OpenZweb] 协议引擎已安装: \(url.path)")
        } catch {
            lastError = error.localizedDescription
            appendLog("[OpenZweb] 下载失败: \(error.localizedDescription)")
        }
    }

    func connect(settings: AppSettings, password: String) {
        reconnectTask?.cancel()
        reconnectTask = nil
        failureDialogMessage = nil
        passwordAuthSucceeded = false
        proxyProbeTask?.cancel()
        proxyProbeTask = nil
        guard phase == .idle || isFailed(phase) else { return }
        // Disable connect button immediately (before any proxy check / IO).
        phase = .preparing
        lastError = nil
        smsError = nil
        isSubmittingSMS = false
        holdSMSSheet = false
        pendingSMSCode = nil
        smsRetryRelaunch = false
        captchaImage = nil
        captchaCode = ""
        smsCode = ""
        lastPassword = password
        lastSettings = settings
        skipSecondaryAuth = settings.preferSkipSecondaryAuth
        smsAllowsSkipSecondary = false
        activeMode = settings.connectionMode
        didAuthenticate = false
        openedCaptchaURLs.removeAll()
        captchaServerURL = nil
        captchaSatisfied = false
        lastCaptchaServerURLString = nil

        // Pre-connect system-proxy check only when we will take over system proxy.
        // If manageSystemProxy is off (coexist with Clash etc.), skip the check so
        // other clients can keep owning the system proxy.
        if settings.manageSystemProxy {
            if skipProxyCheckOnce {
                skipProxyCheckOnce = false
                proxyConflict = nil
                appendLog("[OpenZweb] " + L10n.t("log.skip_once"))
            } else {
                let summary = SystemProxyManager.proxyCheckSummary(
                    httpBind: settings.httpBind,
                    socksBind: settings.socksBind
                )
                appendLog("[OpenZweb] " + L10n.format("log.precheck", summary))
                if SystemProxyManager.isLikelyOpenZwebResidualProxy(
                    httpBind: settings.httpBind,
                    socksBind: settings.socksBind
                ) {
                    appendLog("[OpenZweb] " + L10n.t("log.self_residual"))
                    proxyConflict = nil
                } else if let conflict = SystemProxyManager.detectActiveSystemProxy(
                    httpBind: settings.httpBind,
                    socksBind: settings.socksBind
                ) {
                    proxyConflict = conflict
                    // Stay idle; ContentView shows alert. Credentials already stored.
                    phase = .idle
                    return
                } else {
                    proxyConflict = nil
                }
            }
        } else {
            skipProxyCheckOnce = false
            proxyConflict = nil
            appendLog("[OpenZweb] " + L10n.t("log.skip_manage_off"))
        }

        guard let info = CoreBinaryManager.resolveBinary() else {
            let message = CoreError.binaryNotFound.localizedDescription
            phase = .failed(message)
            lastError = message
            refreshCoreBinary()
            return
        }
        let binary = info.url
        coreBinaryPath = binary.path
        if !info.isNative {
            appendLog("[OpenZweb] 警告: 引擎架构 \(info.arch.rawValue) 非本机原生，将尝试通过 Rosetta 运行")
        }

        if settings.rememberPassword, !settings.username.isEmpty {
            CredentialStore.savePassword(password, account: settings.username)
        } else if !settings.username.isEmpty {
            CredentialStore.deletePassword(account: settings.username)
        }

        appendLog("[OpenZweb] " + L10n.t("log.start_engine"))
        appendLog("[OpenZweb] \(settings.serverAddress):\(settings.serverPort) · \(settings.protocolKind.displayName) · \(settings.connectionMode.displayName)")

        do {
            try startProcess(binary: binary, settings: settings, password: password)
            startCaptchaPolling()
        } catch {
            phase = .failed(error.localizedDescription)
            lastError = error.localizedDescription
            appendLog("[OpenZweb] 启动失败: \(error.localizedDescription)")
        }
    }

    /// zju-connect cannot switch TUN/proxy without restarting the engine (re-auth).
    /// Kept for potential future use; UI no longer exposes this while connected.
    func switchMode(to mode: ConnectionMode) {
        guard phase == .connected else {
            if var settings = lastSettings {
                settings.connectionMode = mode
                lastSettings = settings
            }
            activeMode = mode
            return
        }
        guard var settings = lastSettings else { return }
        guard mode != activeMode else { return }
        settings.connectionMode = mode
        lastSettings = settings
        let password = lastPassword
        appendLog("[OpenZweb] 正在切换连接模式 → \(mode.displayName)…")
        disconnect()
        // disconnect() ends in .idle; reconnect with remembered credentials.
        connect(settings: settings, password: password)
    }

    func disconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
        captchaPollTask?.cancel()
        captchaPollTask = nil
        holdSMSSheet = false
        pendingSMSCode = nil
        smsRetryRelaunch = false
        smsError = nil
        isSubmittingSMS = false
        phase = .disconnecting
        appendLog("[OpenZweb] " + L10n.t("log.disconnecting"))

        if elevated {
            // Best-effort kill elevated process by matching config path
            if let config = runtimeConfigURL {
                let script = """
                do shell script "pkill -f \(shellQuote(config.path)) || true" with administrator privileges
                """
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                p.arguments = ["-e", script]
                try? p.run()
                p.waitUntilExit()
            }
        }

        process?.terminate()
        cleanupProcess()
        wipeRuntimeConfig()
        restoreSystemProxyIfManaged()
        phase = .idle
        connectedSince = nil
        captchaImage = nil
        captchaServerURL = nil
        elevated = false
        didAuthenticate = false
    }

    func submitCaptcha() {
        guard phase == .waitingCaptcha, !captchaCode.isEmpty else { return }
        writeLine(captchaCode)
        captchaCode = ""
        captchaImage = nil
        phase = .authenticating
        appendLog("[OpenZweb] 已提交图形验证码")
    }

    func submitSMS() {
        guard phase == .waitingSMS || holdSMSSheet, !smsCode.isEmpty else { return }
        guard !isSubmittingSMS else { return }
        let raw = smsCode
        let shouldSkip = smsAllowsSkipSecondary && skipSecondaryAuth
        let code = Self.prepareSMSCode(raw, skipSecondary: shouldSkip)
        smsError = nil
        // Keep digits visible and lock input while verifying.
        isSubmittingSMS = true
        holdSMSSheet = true
        phase = .waitingSMS

        if let process, process.isRunning {
            writeLine(code)
            if shouldSkip {
                appendLog("[OpenZweb] " + L10n.t("log.sms_sent_skip"))
                // Persist "skip future secondary SMS" preference.
                if var s = lastSettings {
                    s.preferSkipSecondaryAuth = true
                    lastSettings = s
                    s.save()
                }
            } else {
                appendLog("[OpenZweb] " + L10n.t("log.sms_sent"))
                if var s = lastSettings {
                    s.preferSkipSecondaryAuth = false
                    lastSettings = s
                    s.save()
                }
            }
            // After OTP the engine may open SOCKS/HTTP without a clear log line.
            passwordAuthSucceeded = true
            startProxyReadyProbe()
            return
        }

        pendingSMSCode = code
        appendLog("[OpenZweb] 已提交短信验证码，引擎已退出，正在重新认证后再次提交…")
        relaunchForSMSRetry()
    }

    /// EZ4Connect / zju-connect: prefix SMS with "$" to request skipSecondaryAuth.
    private static func prepareSMSCode(_ raw: String, skipSecondary: Bool) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard skipSecondary, !trimmed.isEmpty else { return trimmed }
        if trimmed.hasPrefix("$") { return trimmed }
        return "$" + trimmed
    }

    func reloadCaptchaFromDisk() {
        // After click-captcha is done, residual graph-code files must not reopen captcha UI.
        guard !captchaSatisfied else { return }
        // Only surface disk captcha while we are still early in login, never after SMS/connected.
        switch phase {
        case .preparing, .authenticating, .waitingCaptcha:
            break
        default:
            return
        }
        let url = CoreBinaryManager.captchaImageURL
        guard FileManager.default.fileExists(atPath: url.path),
              let image = NSImage(contentsOf: url) else { return }
        captchaImage = image
        // Prefer explicit captcha-server logs for aTrust; only fall back to image UI if no server URL.
        if captchaServerURL == nil, phase != .waitingCaptcha {
            phase = .waitingCaptcha
        }
    }

    // MARK: - Process

    private func startProcess(binary: URL, settings: AppSettings, password: String) throws {
        try? FileManager.default.removeItem(at: CoreBinaryManager.captchaImageURL)

        let configURL = try writeRuntimeConfig(settings: settings, password: password)
        runtimeConfigURL = configURL

        if settings.tunMode {
            try startElevated(binary: binary, configURL: configURL)
        } else {
            try startNormal(binary: binary, configURL: configURL)
        }
        phase = .authenticating
    }

    private func startNormal(binary: URL, configURL: URL) throws {
        elevated = false
        let process = Process()
        process.executableURL = binary
        // Do NOT pass -auto-detect-interface: older zju-connect builds treat it as
        // fatal ("flag provided but not defined") and dump -h usage text, which used
        // to be mis-detected as "connected". Prefer config-only / default routing.
        var args = [
            "-config", configURL.path,
            "-graph-code-file", CoreBinaryManager.captchaImageURL.path
        ]
        // Belt-and-suspenders: also pass CLI string form (comma-separated).
        if let settings = lastSettings {
            let domains = Self.expandedProxyDomains(settings.proxyAllowDomains)
            if !domains.isEmpty {
                args += ["-custom-proxy-domain", domains.joined(separator: ",")]
            }
        }
        process.arguments = args
        process.environment = Self.sanitizedProcessEnvironment()

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        attachOutputHandlers(stdout: stdout, stderr: stderr)
        process.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            guard let engine = self else { return }
            Task { @MainActor in
                engine.handleTermination(status: status)
            }
        }
        try process.run()
        self.process = process
        self.stdinPipe = stdin
        self.stdoutPipe = stdout
        self.stderrPipe = stderr
        appendLog("[OpenZweb] 已清除子进程代理环境变量，避免 Fake-IP (198.18.x) 干扰认证")
    }

    /// TUN mode needs root. Launch via admin shell with FIFO for captcha stdin.
    private func startElevated(binary: URL, configURL: URL) throws {
        elevated = true
        appendLog("[OpenZweb] TUN 模式需要管理员权限，将弹出系统授权…")

        let fifo = CoreBinaryManager.stdinFIFOURL
        try? FileManager.default.removeItem(at: fifo)
        let mkfifo = Process()
        mkfifo.executableURL = URL(fileURLWithPath: "/usr/bin/mkfifo")
        mkfifo.arguments = [fifo.path]
        try mkfifo.run()
        mkfifo.waitUntilExit()

        // Open FIFO for writing in background so writer doesn't block forever.
        // Reader side is opened by the elevated shell.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let handle = FileHandle(forWritingAtPath: fifo.path)
            guard let engine = self else { return }
            Task { @MainActor in
                engine.fifoWriteHandle = handle
            }
        }

        let logFile = CoreBinaryManager.supportDirectory.appendingPathComponent("engine.log")
        try? "".write(to: logFile, atomically: true, encoding: .utf8)

        var extraFlags = ""
        if let settings = lastSettings {
            let domains = Self.expandedProxyDomains(settings.proxyAllowDomains)
            if !domains.isEmpty {
                extraFlags = " -custom-proxy-domain \(shellQuote(domains.joined(separator: ",")))"
            }
        }
        let cmd = """
        \(shellQuote(binary.path)) -config \(shellQuote(configURL.path)) -graph-code-file \(shellQuote(CoreBinaryManager.captchaImageURL.path))\(extraFlags) < \(shellQuote(fifo.path)) > \(shellQuote(logFile.path)) 2>&1 &
        echo $!
        """
        let script = "do shell script \(appleScriptString(cmd)) with administrator privileges"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "授权失败"
            throw NSError(domain: "OpenZweb", code: Int(process.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: "TUN 授权失败：\(msg.trimmingCharacters(in: .whitespacesAndNewlines))"
            ])
        }

        // Poll engine log file instead of process pipes
        startLogFilePolling(logFile)
        // Also store a sentinel process — we monitor via pgrep on disconnect
        self.process = nil
        self.stdinPipe = nil
        appendLog("[OpenZweb] 已以管理员权限启动引擎 (TUN)")
    }

    private func startLogFilePolling(_ logFile: URL) {
        captchaPollTask?.cancel()
        captchaPollTask = Task { [weak self] in
            var offset: UInt64 = 0
            for _ in 0..<600 {
                guard !Task.isCancelled else { return }
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard let engine = self else { return }
                await MainActor.run {
                    engine.reloadCaptchaFromDisk()
                    if let handle = try? FileHandle(forReadingFrom: logFile) {
                        defer { try? handle.close() }
                        try? handle.seek(toOffset: offset)
                        let data = handle.readDataToEndOfFile()
                        if !data.isEmpty {
                            offset += UInt64(data.count)
                            if let text = String(data: data, encoding: .utf8) {
                                engine.handleOutput(text)
                            }
                        }
                    }
                }
                let phaseNow = await MainActor.run { engine.phase }
                switch phaseNow {
                case .idle, .failed, .disconnecting:
                    return
                case .connected:
                    continue // keep reading logs while connected
                default:
                    break
                }
            }
        }
    }

    private func attachOutputHandlers(stdout: Pipe, stderr: Pipe) {
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            guard let engine = self else { return }
            Task { @MainActor in engine.handleOutput(text) }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            guard let engine = self else { return }
            Task { @MainActor in engine.handleOutput(text) }
        }
    }

    private func writeRuntimeConfig(settings: AppSettings, password: String) throws -> URL {
        let url = CoreBinaryManager.runtimeConfigURL
        func q(_ s: String) -> String {
            "\"\(s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
        }

        let socksBind = settings.shareOnLAN ? ProxyHelper.lanBind(from: settings.socksBind) : settings.socksBind
        let httpBind = settings.shareOnLAN ? ProxyHelper.lanBind(from: settings.httpBind) : settings.httpBind
        if settings.shareOnLAN {
            appendLog("[OpenZweb] 局域网共享已开启：SOCKS \(socksBind) · HTTP \(httpBind)")
        }

        // Only keys that exist in zju-connect's toml tags (unknown / wrong-type keys cause
        // "error parsing the config file").
        var lines: [String] = [
            "server_address = \(q(settings.serverAddress))",
            "server_port = \(settings.serverPort)",
            "protocol = \(q(settings.protocolKind.rawValue))",
            "auth_type = \(q(settings.authMethod.rawValue))",
            "login_domain = \(q(settings.loginDomain))",
            "username = \(q(settings.username))",
            "password = \(q(password))",
            "socks_bind = \(q(socksBind))",
            "http_bind = \(q(httpBind))",
            "zju_dns_server = \(q(settings.zjuDnsServer.isEmpty ? "auto" : settings.zjuDnsServer))",
            "secondary_dns_server = \(q(settings.secondaryDnsServer.isEmpty ? "114.114.114.114" : settings.secondaryDnsServer))",
            "disable_server_config = \(settings.disableServerConfig)",
            "disable_keep_alive = \(settings.disableKeepAlive)",
            "skip_domain_resource = \(settings.skipDomainResource)",
            "debug_dump = \(settings.debugMode)",
            "tun_mode = \(settings.tunMode)",
            "add_route = \(settings.addRoute)",
            "dns_hijack = \(settings.dnsHijack)",
            "fake_ip = \(settings.fakeIP)",
            "tcp_tunnel_mode = \(settings.tcpTunnelMode)"
        ]
        // Force-through-RVPN domains (zju-connect custom_proxy_domain).
        // Expand bare domains with www. variant so common hostnames match.
        let allowDomains = Self.expandedProxyDomains(settings.proxyAllowDomains)
        if allowDomains.isEmpty {
            appendLog("[OpenZweb] 代理白名单: （空）— 仅校内/服务器资源走 VPN，外网域名默认 DIRECT")
        } else {
            // Go type is []string — must be a TOML array, not a comma-separated string.
            let arr = allowDomains.map { q($0) }.joined(separator: ", ")
            lines.append("custom_proxy_domain = [\(arr)]")
            appendLog("[OpenZweb] 代理白名单(custom_proxy_domain): \(allowDomains.joined(separator: ", "))")
        }
        let denyDomains = settings.proxyDenyDomains
        if denyDomains.isEmpty {
            appendLog("[OpenZweb] 代理黑名单: （空）")
        } else {
            appendLog("[OpenZweb] 代理黑名单(系统代理绕过): \(denyDomains.joined(separator: ", "))")
        }
        // TUN: optional local DNS forwarder (port 53 usually needs privileges).
        if settings.tunMode, settings.manageSystemDNS {
            lines.append("dns_server_bind = \(q("127.0.0.1:53"))")
        }
        let body = lines.joined(separator: "\n") + "\n"
        try body.write(to: url, atomically: true, encoding: .utf8)
        appendLog("[OpenZweb] 运行配置已写入 \(url.path)")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }

    private func wipeRuntimeConfig() {
        if let url = runtimeConfigURL {
            try? FileManager.default.removeItem(at: url)
            runtimeConfigURL = nil
        }
        try? FileManager.default.removeItem(at: CoreBinaryManager.stdinFIFOURL)
        try? fifoWriteHandle?.close()
        fifoWriteHandle = nil
    }

    private func startCaptchaPolling() {
        // Non-TUN: poll captcha image; TUN also starts log polling which reloads captcha
        if elevated { return }
        captchaPollTask?.cancel()
        captchaPollTask = Task { [weak self] in
            for _ in 0..<120 {
                guard !Task.isCancelled else { return }
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let engine = self else { return }
                await MainActor.run { engine.reloadCaptchaFromDisk() }
                let shouldStop = await MainActor.run { () -> Bool in
                    switch engine.phase {
                    case .connected, .idle, .failed: return true
                    default: return false
                    }
                }
                if shouldStop { return }
            }
        }
    }

    private func writeLine(_ line: String) {
        var payload = line
        if !payload.hasSuffix("\n") { payload += "\n" }
        guard let data = payload.data(using: .utf8) else { return }

        if let handle = stdinPipe?.fileHandleForWriting {
            handle.write(data)
            return
        }
        if let handle = fifoWriteHandle {
            handle.write(data)
            return
        }
        // Late-open FIFO writer
        let path = CoreBinaryManager.stdinFIFOURL.path
        if let handle = FileHandle(forWritingAtPath: path) {
            fifoWriteHandle = handle
            handle.write(data)
        }
    }

    private func handleOutput(_ text: String) {
        outputBuffer += text
        let lines = outputBuffer.components(separatedBy: .newlines)
        if !text.hasSuffix("\n") {
            outputBuffer = lines.last ?? ""
            for line in lines.dropLast() { processLogLine(line) }
        } else {
            outputBuffer = ""
            for line in lines where !line.isEmpty { processLogLine(line) }
        }
    }

    private func processLogLine(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        appendLog(trimmed)
        let lower = trimmed.lowercased()

        // aTrust click-captcha: local HTTP page (not a simple text code).
        if lower.contains("captcha server started at") {
            if let url = Self.extractHTTPURL(from: trimmed) {
                let key = url.absoluteString
                // Only first time for this URL / attempt — prevent re-opening captcha after user finished.
                if !captchaSatisfied,
                   lastCaptchaServerURLString != key,
                   phase != .connected,
                   phase != .waitingSMS,
                   !holdSMSSheet {
                    lastCaptchaServerURLString = key
                    captchaServerURL = url
                    holdSMSSheet = false
                    phase = .waitingCaptcha
                    appendLog("[OpenZweb] " + L10n.t("log.captcha_open"))
                } else {
                    captchaServerURL = url
                }
            }
        }

        if lower.contains("captcha code received") {
            captchaSatisfied = true
            captchaImage = nil
            captchaServerURL = nil
            // Remove leftover graph-code image so polling cannot re-trigger captcha UI.
            try? FileManager.default.removeItem(at: CoreBinaryManager.captchaImageURL)
            if phase == .waitingCaptcha {
                phase = .authenticating
            }
            appendLog("[OpenZweb] " + L10n.t("log.captcha_ok"))
        }

        // Legacy EasyConnect image captcha only — never re-open aTrust after click captcha done,
        // and never steal focus from SMS / connected phases.
        if !captchaSatisfied,
           phase != .waitingSMS,
           phase != .connected,
           !holdSMSSheet,
           (lower.contains("graph-code") || lower.contains("graph code"))
            || (lower.contains("请输入") && lower.contains("验证码") && !lower.contains("短信") && !lower.contains("sms")) {
            reloadCaptchaFromDisk()
            if captchaImage != nil, captchaServerURL == nil {
                phase = .waitingCaptcha
            }
        }

        // EZ4Connect / zju-connect tip line appears right before secondary SMS prompt.
        if lower.contains("add prefix") && lower.contains("$") && lower.contains("skip secondary") {
            smsAllowsSkipSecondary = true
            // Default ON (preferSkipSecondaryAuth defaults true); user can uncheck.
            skipSecondaryAuth = lastSettings?.preferSkipSecondaryAuth ?? true
            appendLog("[OpenZweb] 检测到可跳过二次短信验证（提交时在验证码前加 $，仅跳过以后的短信）")
        }

        // Prompt for SMS input — only real stdin prompts, not "SMS message sent" notices.
        if !Self.looksLikeSMSFailure(lower), let kind = Self.smsPromptKind(lower) {
            holdSMSSheet = true
            captchaServerURL = nil
            captchaImage = nil
            phase = .waitingSMS
            // EZ4Connect: only secondary SMS prompt shows skip option.
            // "Please enter the SMS verification code:" → secondary (show skip)
            // "Please enter your SMS code:" → primary SMS login (no skip)
            if kind == .secondary {
                smsAllowsSkipSecondary = true
                // Prefer last choice; default true when tip already seen / first time.
                skipSecondaryAuth = lastSettings?.preferSkipSecondaryAuth ?? true
            } else {
                smsAllowsSkipSecondary = false
                skipSecondaryAuth = false
            }
            if let pending = pendingSMSCode, !pending.isEmpty {
                let code = pending
                pendingSMSCode = nil
                smsError = nil
                writeLine(code)
                appendLog("[OpenZweb] 已自动提交重新输入的短信验证码")
            } else if !smsRetryRelaunch {
                smsError = nil
            }
            smsRetryRelaunch = false
        }

        // Track password success (not full tunnel yet).
        if lower.contains("password-based authentication succeeded") {
            passwordAuthSucceeded = true
            startProxyReadyProbe()
        }

        // After secondary SMS is accepted the engine continues silently — keep probing.
        if passwordAuthSucceeded || phase == .waitingSMS || phase == .authenticating || phase == .connecting {
            if lower.contains("authcheck") || lower.contains("reportenv") || lower.contains("resource") {
                startProxyReadyProbe()
            }
        }

        // Real success signals only — never match "check tun mode cap" etc.
        if Self.looksLikeAuthenticated(lower) {
            markConnected(reason: trimmed)
        }

        // Wrong SMS code — soft failure: keep OTP sheet, shake, clear digits.
        if Self.looksLikeSMSFailure(lower) {
            handleSMSFailure(from: trimmed)
            return
        }

        // Hard auth / setup failures (do not mark connected) — never auto-retry here.
        if Self.looksLikeAuthFailure(lower) {
            let message = Self.friendlyAuthError(from: trimmed)
            holdSMSSheet = false
            pendingSMSCode = nil
            smsRetryRelaunch = false
            didAuthenticate = false
            reconnectTask?.cancel()
            reconnectTask = nil
            lastError = message
            // Defer dialog to termination for process-exit cases; for CLI usage dumps
            // mark failed immediately so UI doesn't flash "connected".
            if phase != .connected {
                phase = .failed(message)
            }
            appendLog("[OpenZweb] " + L10n.format("log.auth_fail", message))
        }

        // Fake-IP / proxy leak hint
        if trimmed.contains("198.18.") || lower.contains("can't assign requested address") {
            appendLog("[OpenZweb] 提示: 检测到 198.18.x / 地址分配失败，多半是 Clash/Surge Fake-IP 或系统代理劫持了 vpn.zju.edu.cn。请对 VPN 域名直连，并关闭对 zju-connect 的代理。")
        }
    }

    private func markConnected(reason: String) {
        guard phase != .connected else { return }
        proxyProbeTask?.cancel()
        proxyProbeTask = nil
        didAuthenticate = true
        captchaSatisfied = true
        holdSMSSheet = false
        pendingSMSCode = nil
        smsRetryRelaunch = false
        smsError = nil
        isSubmittingSMS = false
        captchaImage = nil
        phase = .connected
        connectedSince = Date()
        captchaServerURL = nil
        if !elevated { captchaPollTask?.cancel() }
        wipeSensitivePasswordOnly()
        appendLog("[OpenZweb] " + L10n.format("log.tunnel_up", activeMode.displayName))
        if activeMode == .proxy {
            applySystemProxyIfNeededAsync()
        }
    }

    /// Never block the main actor with networksetup / admin prompts.
    private func applySystemProxyIfNeededAsync() {
        guard let settings = lastSettings else { return }
        let extraBypass = settings.proxyDenyDomains
        let socks = SystemProxyManager.Endpoint.parse(settings.socksBind).map { "127.0.0.1:\($0.port)" } ?? settings.socksBind
        let http = SystemProxyManager.Endpoint.parse(settings.httpBind).map { "127.0.0.1:\($0.port)" } ?? settings.httpBind
        let manageProxy = settings.manageSystemProxy
        let manageDNS = settings.manageSystemDNS
        // NEVER push campus 10.x into macOS system DNS in proxy mode — UDP to 10.x
        // does not go through SOCKS, so every lookup becomes "no such host".
        let dnsForSystem: [String]?
        if manageDNS {
            if settings.tunMode {
                dnsForSystem = ["127.0.0.1"]
            } else {
                let pub = settings.secondaryDnsServer.isEmpty ? "114.114.114.114" : settings.secondaryDnsServer
                dnsForSystem = [pub, "8.8.8.8"]
            }
        } else {
            dnsForSystem = nil
        }

        if manageProxy || manageDNS {
            appendLog("[OpenZweb] " + L10n.t("log.proxy_applying"))
            if manageDNS {
                if settings.tunMode {
                    appendLog("[OpenZweb] DNS 策略（TUN）：系统 DNS → 127.0.0.1，校内解析走隧道")
                } else {
                    appendLog("[OpenZweb] DNS 策略（代理）：系统 DNS → 公共 DNS（不会写入 10.x）。浏览器走系统代理；校内域名请用 www.cc98.org")
                }
            }
        }

        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try SystemProxyManager.applyProxyAndDNS(
                    httpBind: http,
                    socksBind: socks,
                    dnsServers: dnsForSystem,
                    manageProxy: manageProxy,
                    manageDNS: manageDNS,
                    extraBypassDomains: extraBypass
                )
                guard let engine = self else { return }
                await MainActor.run {
                    engine.systemProxyManaged = manageProxy
                    if manageProxy {
                        engine.appendLog("[OpenZweb] " + L10n.format("log.proxy_set", http, socks))
                    }
                    if manageDNS, let dnsForSystem {
                        engine.appendLog("[OpenZweb] 已设置系统 DNS → \(dnsForSystem.joined(separator: ", "))")
                    }
                }
            } catch {
                let message = error.localizedDescription
                guard let engine = self else { return }
                await MainActor.run {
                    engine.systemProxyManaged = false
                    engine.appendLog("[OpenZweb] 系统代理/DNS 配置失败：\(message)")
                }
            }
        }
    }

    private func restoreSystemProxyIfManaged() {
        let needs = systemProxyManaged
            || UserDefaults.standard.bool(forKey: "openzweb.systemProxy.applied")
            || UserDefaults.standard.bool(forKey: "openzweb.systemDNS.applied")
        guard needs else { return }
        systemProxyManaged = false
        appendLog("[OpenZweb] " + L10n.t("log.proxy_restoring"))
        Task.detached(priority: .userInitiated) { [weak self] in
            SystemProxyManager.restoreAllIfNeeded()
            guard let engine = self else { return }
            await MainActor.run {
                engine.appendLog("[OpenZweb] " + L10n.t("log.proxy_restore"))
            }
        }
    }

    /// Strip HTTP(S)/SOCKS proxy env so aTrust login is not sucked into Clash Fake-IP.
    /// Also put a no-op `open` ahead of PATH so zju-connect does not spawn Safari for captcha.
    private static func sanitizedProcessEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let keys = [
            "http_proxy", "https_proxy", "HTTP_PROXY", "HTTPS_PROXY",
            "all_proxy", "ALL_PROXY", "socks_proxy", "SOCKS_PROXY",
            "ftp_proxy", "FTP_PROXY"
        ]
        for key in keys { env.removeValue(forKey: key) }
        env["NO_PROXY"] = "*"
        env["no_proxy"] = "*"
        // pkg/browser-style openers often honor BROWSER; force a no-op.
        env["BROWSER"] = Self.stubOpenPath()
        // Prepend stub dir so bare `open` / `xdg-open` resolve to our no-op first.
        // Note: code that hardcodes /usr/bin/open still needs the absolute BROWSER/stub approach below.
        let stubDir = URL(fileURLWithPath: Self.stubOpenPath()).deletingLastPathComponent().path
        let path = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        if !path.split(separator: ":").map(String.init).contains(stubDir) {
            env["PATH"] = stubDir + ":" + path
        }
        return env
    }

    /// Absolute path to Tools/open next to the app bundle or project tree.
    private static func stubOpenPath() -> String {
        var candidates: [String] = []
        if let resource = Bundle.main.resourceURL?.appendingPathComponent("Tools/open").path {
            candidates.append(resource)
        }
        candidates.append(Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/Tools/open").path)
        candidates.append(
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Tools/open").path
        )
        candidates.append(FileManager.default.currentDirectoryPath + "/Tools/open")
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return "/usr/bin/true"
    }

    private static func extractHTTPURL(from line: String) -> URL? {
        // e.g. Captcha server started at http://127.0.0.1:65099
        guard let range = line.range(of: #"https?://[^\s]+"#, options: .regularExpression) else {
            return nil
        }
        var raw = String(line[range])
        while raw.last?.isPunctuation == true { raw.removeLast() }
        return URL(string: raw)
    }

    /// When auth finished, zju-connect may not print a clear "listening" line.
    /// Probe local SOCKS/HTTP binds so we still enter .connected reliably.
    private func startProxyReadyProbe() {
        guard let settings = lastSettings else { return }
        if proxyProbeTask != nil { return }
        // TUN mode has no local socks necessarily in the same way — skip.
        if settings.tunMode { return }
        let socks = settings.shareOnLAN ? ProxyHelper.lanBind(from: settings.socksBind) : settings.socksBind
        let http = settings.shareOnLAN ? ProxyHelper.lanBind(from: settings.httpBind) : settings.httpBind
        proxyProbeTask = Task { [weak self] in
            for _ in 0..<60 {
                guard !Task.isCancelled else { return }
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let engine = self else { return }
                let ready = await MainActor.run { () -> Bool in
                    switch engine.phase {
                    case .connected, .idle, .failed, .disconnecting:
                        return true // stop probe
                    case .waitingCaptcha:
                        return false // user still solving captcha
                    case .waitingSMS:
                        // While user is typing OTP, do not connect yet.
                        // After submit (isSubmittingSMS), ports may come up — allow probe.
                        if !engine.isSubmittingSMS { return false }
                    default:
                        break
                    }
                    let socksUp = Self.isLocalEndpointOpen(socks)
                    let httpUp = Self.isLocalEndpointOpen(http)
                    if socksUp || httpUp {
                        engine.markConnected(reason: "local proxy port open")
                        return true
                    }
                    return false
                }
                if ready {
                    await MainActor.run { self?.proxyProbeTask = nil }
                    return
                }
            }
            await MainActor.run { self?.proxyProbeTask = nil }
        }
    }

    private static func isLocalEndpointOpen(_ bind: String) -> Bool {
        guard let endpoint = SystemProxyManager.Endpoint.parse(bind) else { return false }
        let host: String
        if endpoint.host.isEmpty || endpoint.host == "0.0.0.0" || endpoint.host == "::" || endpoint.host == "*" {
            host = "127.0.0.1"
        } else {
            host = endpoint.host
        }
        var hints = addrinfo(
            ai_flags: 0,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: 0,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var result: UnsafeMutablePointer<addrinfo>?
        let portStr = String(endpoint.port)
        guard getaddrinfo(host, portStr, &hints, &result) == 0, let first = result else { return false }
        defer { freeaddrinfo(result) }
        let fd = socket(first.pointee.ai_family, first.pointee.ai_socktype, first.pointee.ai_protocol)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        let rc = Darwin.connect(fd, first.pointee.ai_addr, first.pointee.ai_addrlen)
        if rc == 0 { return true }
        if errno == EINPROGRESS {
            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let pr = Darwin.poll(&pfd, 1, 120)
            if pr > 0, (pfd.revents & Int16(POLLOUT)) != 0 {
                var err: Int32 = 0
                var len = socklen_t(MemoryLayout<Int32>.size)
                if getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len) == 0, err == 0 {
                    return true
                }
            }
        }
        return false
    }

    /// Normalize + expand allow-list domains for zju-connect matching.
    /// Bare "google.com" also yields "www.google.com"; wildcards stripped to suffix form.
    private static func expandedProxyDomains(_ raw: [String]) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        func add(_ d: String) {
            let t = d.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !t.isEmpty, !seen.contains(t) else { return }
            seen.insert(t)
            out.append(t)
        }
        for item in raw {
            var d = item.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if d.hasPrefix("*.") { d = String(d.dropFirst(2)) }
            if d.hasPrefix(".") { d = String(d.dropFirst()) }
            guard !d.isEmpty else { continue }
            add(d)
            // Common host prefix — many sites only hit www.*
            if !d.hasPrefix("www.") {
                add("www." + d)
            }
        }
        return out
    }

    /// Fatal CLI / config errors that must fail the session (not mere help lines).
    private static func looksLikeCLIUsageOrFatal(_ lower: String) -> Bool {
        if lower.contains("flag provided but not defined") { return true }
        if lower.hasPrefix("usage of") || lower.contains("usage of ") { return true }
        if lower.contains("error parsing the config file") { return true }
        return false
    }

    /// Help-text noise from `zju-connect -h` dumps — never treat as tunnel-up.
    private static func looksLikeHelpNoise(_ lower: String) -> Bool {
        if looksLikeCLIUsageOrFatal(lower) { return true }
        if lower.contains("the address") && lower.contains("listens on") { return true }
        if lower.contains("(default ") || lower.contains("(default:") { return true }
        if lower.contains("e.g.") && (lower.contains("127.0.0.1") || lower.contains("socks") || lower.contains("http")) {
            return true
        }
        // Flag name lines like "-socks-bind string"
        if lower.hasPrefix("-") && !lower.contains("error") { return true }
        return false
    }

    private static func looksLikeAuthenticated(_ lower: String) -> Bool {
        // Never treat CLI help / unknown-flag dumps as success.
        if looksLikeHelpNoise(lower) { return false }

        if lower.contains("login success") || lower.contains("登录成功") {
            return true
        }
        // Password-only step success is NOT tunnel ready (SMS may follow).
        if lower.contains("password-based authentication succeeded") { return false }
        if lower.contains("authentication succeeded") && lower.contains("password") { return false }
        // Avoid "Captcha server started at http://..."
        if lower.contains("captcha") { return false }
        // Avoid init: "check tun mode cap"
        if lower.contains("exec func on initial") { return false }
        if lower.contains("check tun mode") { return false }
        if lower.contains("sms") { return false }

        // Real runtime listen notices (not help text "The address … listens on").
        if lower.contains("socks") && lower.contains("listening") { return true }
        if lower.contains("socks5") && lower.contains("started") { return true }
        if lower.contains("http") && lower.contains("listening") && lower.contains("proxy") { return true }
        if lower.contains("http server") && lower.contains("start") { return true }
        if lower.contains("proxy server") && (lower.contains("start") || lower.contains("listen")) { return true }
        // TUN ready (real device bring-up, not capability check)
        if lower.contains("tun device") || lower.contains("created tun") || lower.contains("interface up") {
            return true
        }
        // zju-connect often logs Start ZJU Connect then later success; require explicit ready signals.
        if lower.contains("vpn connected") || lower.contains("tunnel established") || lower.contains("connected to server") {
            return true
        }
        return false
    }



    private func handleSMSFailure(from line: String) {
        let message = Self.friendlySMSError(from: line)
        lastError = message
        smsError = message
        isSubmittingSMS = false
        holdSMSSheet = true
        if phase != .connected {
            phase = .waitingSMS
        }
        // Shake with digits still visible, then clear for re-entry.
        smsShakeToken += 1
        let token = smsShakeToken
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard token == smsShakeToken, !isSubmittingSMS else { return }
            smsCode = ""
        }
        appendLog("[OpenZweb] " + L10n.format("log.sms_fail", message))
    }

    /// Relaunch zju-connect after a dead process so the user can re-submit SMS.
    private func relaunchForSMSRetry() {
        guard let settings = lastSettings else {
            phase = .failed("无法重试：缺少连接配置")
            holdSMSSheet = false
            return
        }
        guard !lastPassword.isEmpty else {
            phase = .failed("无法重试：请重新输入密码后连接")
            holdSMSSheet = false
            return
        }
        smsRetryRelaunch = true
        holdSMSSheet = true
        phase = .waitingSMS
        restartProcessKeepingSMSSheet(settings: settings, password: lastPassword)
    }

    private func restartProcessKeepingSMSSheet(settings: AppSettings, password: String) {
        reconnectTask?.cancel()
        captchaPollTask?.cancel()
        if let process, process.isRunning {
            process.terminate()
        }
        cleanupProcess()
        wipeRuntimeConfig()

        activeMode = settings.connectionMode
        didAuthenticate = false
        openedCaptchaURLs.removeAll()
        captchaServerURL = nil
        captchaSatisfied = false
        lastCaptchaServerURLString = nil

        guard let info = CoreBinaryManager.resolveBinary() else {
            let message = CoreError.binaryNotFound.localizedDescription
            lastError = message
            smsError = message
            smsShakeToken += 1
            phase = .waitingSMS
            return
        }
        coreBinaryPath = info.url.path
        appendLog("[OpenZweb] 为短信重试重新启动协议引擎…")
        do {
            try startProcess(binary: info.url, settings: settings, password: password)
            startCaptchaPolling()
            phase = .waitingSMS
        } catch {
            lastError = error.localizedDescription
            smsError = error.localizedDescription
            smsShakeToken += 1
            phase = .waitingSMS
            appendLog("[OpenZweb] 短信重试启动失败: \(error.localizedDescription)")
        }
    }

    private static func looksLikeSMSUserMessage(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("短信") || lower.contains("sms") || lower.contains("验证码")
    }

    /// EZ4Connect parity:
    /// - "Please enter the SMS verification code:" -> secondary auth (may skip with $)
    /// - "Please enter your SMS code:" -> primary SMS login (no skip)
    private static func looksLikeSMSPrompt(_ lower: String) -> Bool {
        smsPromptKind(lower) != nil
    }

    private static func smsPromptKind(_ lower: String) -> SMSPromptKind? {
        if lower.contains("please enter the sms verification code") {
            return .secondary
        }
        if lower.contains("please enter your sms code") {
            return .primary
        }
        if lower.contains("please enter") && lower.contains("sms") && lower.contains("verification") {
            return .secondary
        }
        if lower.contains("请输入") && lower.contains("短信") {
            return .secondary
        }
        return nil
    }

    private enum SMSPromptKind {
        case primary
        case secondary
    }

    private static func looksLikeSMSFailure(_ lower: String) -> Bool {
        if lower.contains("smscheckcode") && (lower.contains("failed") || lower.contains("incorrect") || lower.contains("error")) {
            return true
        }
        if lower.contains("verification code is incorrect") { return true }
        if lower.contains("sms") && lower.contains("incorrect") { return true }
        if lower.contains("短信") && (lower.contains("错误") || lower.contains("不正确") || lower.contains("失败")) {
            return true
        }
        // Login/setup wrappers around SMS failures
        if (lower.contains("login error") || lower.contains("vpn client setup error"))
            && (lower.contains("sms") || lower.contains("verification code")) {
            return true
        }
        return false
    }

    private static func looksLikeAuthFailure(_ lower: String) -> Bool {
        // SMS wrong-code is handled as a soft failure.
        if looksLikeSMSFailure(lower) { return false }
        if looksLikeCLIUsageOrFatal(lower) { return true }
        if lower.contains("login error") { return true }
        if lower.contains("vpn client setup error") { return true }
        if lower.contains("ticket is empty") { return true }
        if lower.contains("username/password is incorrect") { return true }
        if lower.contains("password is incorrect") { return true }
        if lower.contains("auth failed") || lower.contains("login failed") { return true }
        if lower.contains("认证失败") || lower.contains("密码错误") { return true }
        if lower.contains("authentication failed") { return true }
        // Expired captcha text only — not fatal by itself if engine retries
        return false
    }

    private static func friendlySMSError(from line: String) -> String {
        let lower = line.lowercased()
        // "You still have 9 attempts left"
        if let range = lower.range(of: #"still have\s+(\d+)\s+attempts?"#, options: .regularExpression) {
            let snippet = String(lower[range])
            let digits = snippet.filter(\.isNumber)
            if let n = Int(digits), n > 0 {
                return "短信验证码错误，还可尝试 \(n) 次"
            }
        }
        if lower.contains("incorrect") || lower.contains("错误") || lower.contains("不正确") {
            return "短信验证码错误，请重新输入"
        }
        return "短信验证码验证失败，请重新输入"
    }

    private static func friendlyAuthError(from line: String) -> String {
        let lower = line.lowercased()
        if looksLikeSMSFailure(lower) {
            return friendlySMSError(from: line)
        }
        // Only map true password failures — bare "incorrect" is often SMS.
        if lower.contains("username/password")
            || lower.contains("password is incorrect")
            || (lower.contains("password-based authentication") && (lower.contains("fail") || lower.contains("error")))
            || lower.contains("密码错误")
            || lower.contains("用户名或密码") {
            return "用户名或密码错误（请确认学号密码 / 登录域 Radius）"
        }
        if lower.contains("ticket is empty") {
            return "登录未完成（ticket 为空）。若使用统一身份认证，请在登录页选择「CAS」认证方式。"
        }
        if lower.contains("198.18") || lower.contains("can't assign") {
            return "无法连接 VPN 服务器（疑似系统代理/Fake-IP）。请让 vpn.zju.edu.cn 直连后重试。"
        }
        if lower.contains("flag provided but not defined") {
            return "协议引擎版本过旧或不兼容（不支持当前启动参数）。请在应用内重新下载内核，或替换 Core/zju-connect 后重试。"
        }
        if lower.contains("error parsing the config file") {
            return "运行配置无法解析（内核版本与配置不兼容）。请更新 zju-connect 内核后重试。"
        }
        if looksLikeCLIUsageOrFatal(lower) {
            return "协议引擎启动失败（参数/配置不兼容）。请更新内核后重试。"
        }
        return line
    }

    private func wipeSensitivePasswordOnly() {
        // Keep config for TUN process but blank password field after connect when possible
        // Full wipe after disconnect.
    }

    private func handleTermination(status: Int32) {
        let wasAuthenticated = didAuthenticate
        captchaPollTask?.cancel()
        proxyProbeTask?.cancel()
        proxyProbeTask = nil
        passwordAuthSucceeded = false
        cleanupProcess()
        wipeRuntimeConfig()
        restoreSystemProxyIfManaged()

        if phase == .disconnecting || phase == .idle {
            phase = .idle
            holdSMSSheet = false
            pendingSMSCode = nil
            smsRetryRelaunch = false
            didAuthenticate = false
            return
        }

        if status == 0 && wasAuthenticated {
            phase = .idle
            holdSMSSheet = false
            pendingSMSCode = nil
            smsRetryRelaunch = false
            connectedSince = nil
            didAuthenticate = false
            appendLog("[OpenZweb] 连接已结束")
            return
        }

        // Wrong SMS often kills the engine — keep OTP sheet so user can re-enter.
        if holdSMSSheet || phase == .waitingSMS || (smsError != nil && !wasAuthenticated) {
            phase = .waitingSMS
            holdSMSSheet = true
            connectedSince = nil
            didAuthenticate = false
            if smsError == nil, let lastError, Self.looksLikeSMSUserMessage(lastError) {
                smsError = lastError
            }
            appendLog("[OpenZweb] 短信验证未通过，请继续在当前页面输入验证码")
            return
        }

        let message = lastError ?? "进程退出 (code \(status))"
        holdSMSSheet = false
        pendingSMSCode = nil
        smsRetryRelaunch = false
        connectedSince = nil
        didAuthenticate = false
        reconnectTask?.cancel()
        reconnectTask = nil

        // Login/startup failures must never auto-reconnect. Only a previously
        // healthy connected session may reconnect (and only if user enabled it).
        if wasAuthenticated, let settings = lastSettings, settings.autoReconnect, status != 0 {
            phase = .failed(message)
            appendLog("[OpenZweb] \(message)")
            appendLog("[OpenZweb] 连接意外中断，将按设置尝试自动重连")
            scheduleReconnect()
            return
        }

        // Hard failure: dialog + stop. No silent retries.
        presentFailure(message, log: true)
    }

    private func scheduleReconnect() {
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            guard let engine = self else { return }
            engine.appendLog("[OpenZweb] 5 秒后自动重连…")
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            if let settings = engine.lastSettings {
                engine.phase = .idle
                engine.connect(settings: settings, password: engine.lastPassword)
            }
        }
    }

    private func cleanupProcess() {
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        try? stdinPipe?.fileHandleForWriting.close()
        process = nil
        stdinPipe = nil
        stdoutPipe = nil
        stderrPipe = nil
        try? fifoWriteHandle?.close()
        fifoWriteHandle = nil
        elevated = false
    }

    private func appendLog(_ line: String) {
        let stamp = Self.timeFormatter.string(from: Date())
        logs.append("[\(stamp)] \(line)")
        if logs.count > 2000 { logs.removeFirst(logs.count - 2000) }
    }

    private func isFailed(_ phase: ConnectionPhase) -> Bool {
        if case .failed = phase { return true }
        return false
    }

    private func shellQuote(_ s: String) -> String {
        "'\(s.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private func appleScriptString(_ s: String) -> String {
        "\"\(s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}
