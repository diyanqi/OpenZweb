import Foundation
import AppKit
import Combine

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
    @Published private(set) var lastError: String?
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

    /// Only used by the connect-time alert actions (re-check / dismiss).
    func refreshProxyConflict(settings: AppSettings? = nil) {
        _ = settings
        proxyConflict = SystemProxyManager.detectActiveSystemProxy()
    }

    func dismissProxyConflictWarning() {
        proxyConflict = nil
        // Next connect may proceed once without re-blocking.
        skipProxyCheckOnce = true
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
        guard phase == .idle || isFailed(phase) else { return }
        lastError = nil
        smsError = nil
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
                appendLog("[OpenZweb] 连接前检查：已按用户选择跳过一次系统代理检测")
            } else {
                let summary = SystemProxyManager.proxyCheckSummary()
                appendLog("[OpenZweb] 连接前检查：\(summary)")
                if let conflict = SystemProxyManager.detectActiveSystemProxy() {
                    proxyConflict = conflict
                    // Stay idle; ContentView shows alert.
                    return
                }
                proxyConflict = nil
            }
        } else {
            skipProxyCheckOnce = false
            proxyConflict = nil
            appendLog("[OpenZweb] 连接前检查：已跳过（未开启「连接后自动设置系统代理」，可与其他代理共存）")
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

        phase = .preparing
        appendLog("[OpenZweb] 启动 aTrust 协议引擎…")
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

    /// Switch proxy/TUN while connected by reconnecting with the new mode.
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
        phase = .disconnecting
        appendLog("[OpenZweb] 正在断开连接…")

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
        let raw = smsCode
        let shouldSkip = smsAllowsSkipSecondary && skipSecondaryAuth
        let code = Self.prepareSMSCode(raw, skipSecondary: shouldSkip)
        smsError = nil
        smsCode = ""
        holdSMSSheet = true
        phase = .waitingSMS

        if let process, process.isRunning {
            writeLine(code)
            if shouldSkip {
                appendLog("[OpenZweb] 已提交短信验证码（$ 前缀：请求跳过以后的短信验证）")
            } else {
                appendLog("[OpenZweb] 已提交短信验证码")
            }
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
        process.arguments = [
            "-config", configURL.path,
            "-graph-code-file", CoreBinaryManager.captchaImageURL.path,
            // Avoid routing aTrust control plane through Clash/Surge TUN / wrong iface.
            "-auto-detect-interface"
        ]
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

        let cmd = """
        \(shellQuote(binary.path)) -config \(shellQuote(configURL.path)) -graph-code-file \(shellQuote(CoreBinaryManager.captchaImageURL.path)) < \(shellQuote(fifo.path)) > \(shellQuote(logFile.path)) 2>&1 &
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
            "server_address = \(q("\(settings.serverAddress):\(settings.serverPort)"))",
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
            "tcp_tunnel_mode = \(settings.tcpTunnelMode)",
            "auto_detect_interface = true"
        ]
        let allowDomains = settings.proxyAllowDomains
        if !allowDomains.isEmpty {
            // zju-connect expects comma-separated domains that force RVPN proxy.
            lines.append("custom_proxy_domain = \(q(allowDomains.joined(separator: ",")))")
            appendLog("[OpenZweb] 代理白名单: \(allowDomains.joined(separator: ", "))")
        }
        let denyDomains = settings.proxyDenyDomains
        if !denyDomains.isEmpty {
            appendLog("[OpenZweb] 代理黑名单(PAC/系统分流): \(denyDomains.joined(separator: ", "))")
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
                    appendLog("[OpenZweb] 人机验证页面已在应用内打开，请点选验证码")
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
            appendLog("[OpenZweb] 已收到验证码，继续认证…")
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

        // Prompt for SMS input — only real stdin prompts, not "SMS message sent" notices.
        if !Self.looksLikeSMSFailure(lower), let kind = Self.smsPromptKind(lower) {
            holdSMSSheet = true
            captchaServerURL = nil
            captchaImage = nil
            phase = .waitingSMS
            // EZ4Connect: only secondary SMS prompt shows skip option.
            smsAllowsSkipSecondary = (kind == .secondary)
            if smsAllowsSkipSecondary {
                skipSecondaryAuth = lastSettings?.preferSkipSecondaryAuth ?? skipSecondaryAuth
            } else {
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

        // Real success signals only — never match "check tun mode cap" etc.
        if Self.looksLikeAuthenticated(lower) {
            markConnected(reason: trimmed)
        }

        // Wrong SMS code — soft failure: keep OTP sheet, shake, clear digits.
        if Self.looksLikeSMSFailure(lower) {
            handleSMSFailure(from: trimmed)
            return
        }

        // Hard auth / setup failures (do not mark connected)
        if Self.looksLikeAuthFailure(lower) {
            lastError = Self.friendlyAuthError(from: trimmed)
            holdSMSSheet = false
            pendingSMSCode = nil
            smsRetryRelaunch = false
            // Stay in failed once process dies; surface message immediately.
            if phase != .connected {
                phase = .failed(lastError!)
            }
            appendLog("[OpenZweb] 认证失败: \(lastError!)")
        }

        // Fake-IP / proxy leak hint
        if trimmed.contains("198.18.") || lower.contains("can't assign requested address") {
            appendLog("[OpenZweb] 提示: 检测到 198.18.x / 地址分配失败，多半是 Clash/Surge Fake-IP 或系统代理劫持了 vpn.zju.edu.cn。请对 VPN 域名直连，并关闭对 zju-connect 的代理。")
        }
    }

    private func markConnected(reason: String) {
        guard phase != .connected else { return }
        didAuthenticate = true
        captchaSatisfied = true
        holdSMSSheet = false
        pendingSMSCode = nil
        smsRetryRelaunch = false
        smsError = nil
        captchaImage = nil
        phase = .connected
        connectedSince = Date()
        captchaServerURL = nil
        if !elevated { captchaPollTask?.cancel() }
        wipeSensitivePasswordOnly()
        appendLog("[OpenZweb] 隧道已建立 (\(activeMode.displayName))")
        if activeMode == .proxy {
            applySystemProxyIfNeededAsync()
        }
    }

    /// Never block the main actor with networksetup / admin prompts.
    private func applySystemProxyIfNeededAsync() {
        guard let settings = lastSettings else { return }
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
            appendLog("[OpenZweb] 正在后台配置系统代理/DNS（不阻塞界面）…")
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
                    manageDNS: manageDNS
                )
                guard let engine = self else { return }
                await MainActor.run {
                    engine.systemProxyManaged = manageProxy
                    if manageProxy {
                        engine.appendLog("[OpenZweb] 已设置系统代理 → HTTP \(http) · SOCKS \(socks)")
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
        appendLog("[OpenZweb] 正在后台恢复系统代理/DNS…")
        Task.detached(priority: .userInitiated) { [weak self] in
            SystemProxyManager.restoreAllIfNeeded()
            guard let engine = self else { return }
            await MainActor.run {
                engine.appendLog("[OpenZweb] 已恢复连接前的系统代理/DNS")
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

    private static func looksLikeAuthenticated(_ lower: String) -> Bool {
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

        if lower.contains("socks") && (lower.contains("listen") || lower.contains("start")) {
            return true
        }
        if lower.contains("http") && lower.contains("listen") && lower.contains("proxy") {
            return true
        }
        // TUN ready (real device bring-up, not capability check)
        if lower.contains("tun device") || lower.contains("created tun") || lower.contains("interface up") {
            return true
        }
        return false
    }



    private func handleSMSFailure(from line: String) {
        let message = Self.friendlySMSError(from: line)
        lastError = message
        smsError = message
        smsCode = ""
        smsShakeToken += 1
        holdSMSSheet = true
        if phase != .connected {
            phase = .waitingSMS
        }
        appendLog("[OpenZweb] 短信验证码错误: \(message)")
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
        return line
    }

    private func wipeSensitivePasswordOnly() {
        // Keep config for TUN process but blank password field after connect when possible
        // Full wipe after disconnect.
    }

    private func handleTermination(status: Int32) {
        let wasAuthenticated = didAuthenticate
        captchaPollTask?.cancel()
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
        phase = .failed(message)
        holdSMSSheet = false
        pendingSMSCode = nil
        smsRetryRelaunch = false
        connectedSince = nil
        appendLog("[OpenZweb] \(message)")

        // Only auto-reconnect after a real authenticated session drops (not captcha/login failures).
        if let settings = lastSettings, settings.autoReconnect, wasAuthenticated {
            scheduleReconnect()
        }
        didAuthenticate = false
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
