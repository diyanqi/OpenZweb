import Foundation
import Darwin

/// Persistent root agent: one admin password prompt, then run TUN/network scripts without re-prompting.
/// Protocol: app drops `queue/<id>.req` shell scripts; agent runs them as root and writes `.status`/`.out`/`.done`.
enum ElevatedSession {
    enum SessionError: LocalizedError {
        case agentStartFailed(String)
        case agentNotRunning
        case commandTimeout
        case commandFailed(Int, String)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .agentStartFailed(let s): return "无法启动管理员助手：\(s)"
            case .agentNotRunning: return "管理员助手未运行"
            case .commandTimeout: return "管理员命令超时"
            case .commandFailed(let code, let out):
                let tail = out.trimmingCharacters(in: .whitespacesAndNewlines)
                if tail.isEmpty { return "管理员命令失败 (exit \(code))" }
                return "管理员命令失败 (exit \(code))：\(tail.prefix(400))"
            case .cancelled: return "已取消管理员授权"
            }
        }
    }

    private static let lock = NSLock()
    private static var launching = false

    static var rootDir: URL {
        CoreBinaryManager.supportDirectory.appendingPathComponent("elevated", isDirectory: true)
    }
    static var queueDir: URL { rootDir.appendingPathComponent("queue", isDirectory: true) }
    static var agentScriptURL: URL { rootDir.appendingPathComponent("agent.sh") }
    static var agentPIDURL: URL { rootDir.appendingPathComponent("agent.pid") }
    static var agentLogURL: URL { rootDir.appendingPathComponent("agent.log") }
    static var quitFlagURL: URL { rootDir.appendingPathComponent("quit") }
    static var enginePIDURL: URL { rootDir.appendingPathComponent("engine.pid") }

    static func isAgentRunning() -> Bool {
        guard let pid = readPID(from: agentPIDURL), pid > 1 else { return false }
        return isPIDAlive(pid)
    }

    /// Ensure root agent is up. May show **one** admin password dialog. Safe off main thread.
    /// Does not hold the session lock while the password sheet is visible (avoids freezing other callers).
    static func ensureAgent(timeout: TimeInterval = 180) throws {
        // Fast path
        if isAgentRunning() { return }

        // Serialize launch without holding lock during osascript password UI.
        while true {
            lock.lock()
            if isAgentRunning() {
                lock.unlock()
                return
            }
            if launching {
                lock.unlock()
                // Another thread is showing the password dialog / starting agent.
                let waitDeadline = Date().addingTimeInterval(timeout)
                while Date() < waitDeadline {
                    if isAgentRunning() { return }
                    Thread.sleep(forTimeInterval: 0.15)
                }
                if isAgentRunning() { return }
                throw SessionError.agentStartFailed("等待管理员助手启动超时")
            }
            launching = true
            lock.unlock()
            break
        }

        defer {
            lock.lock()
            launching = false
            lock.unlock()
        }

        try prepareLayout()
        try writeAgentScript()

        // Clear stale quit / queue leftovers that would confuse a new agent.
        try? FileManager.default.removeItem(at: quitFlagURL)

        let script = """
        set -e
        BASE=\(shQuote(rootDir.path))
        mkdir -p "$BASE/queue"
        chmod 755 "$BASE" 2>/dev/null || true
        chmod 777 "$BASE/queue" 2>/dev/null || true
        if [ -f "$BASE/agent.pid" ]; then
          old=$(cat "$BASE/agent.pid" 2>/dev/null || true)
          if [ -n "$old" ] && kill -0 "$old" 2>/dev/null; then
            echo "$old"
            exit 0
          fi
        fi
        rm -f "$BASE/quit"
        /bin/bash \(shQuote(agentScriptURL.path)) >>\(shQuote(agentLogURL.path)) 2>&1 &
        echo $!
        """

        let out: String
        do {
            out = try runOsascriptAdmin(script, timeout: timeout)
        } catch {
            let msg = error.localizedDescription
            if msg.lowercased().contains("user canceled") || msg.contains("取消") || msg.contains("-128") {
                throw SessionError.cancelled
            }
            throw SessionError.agentStartFailed(msg)
        }

        let token = out.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).last.map(String.init) ?? out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pid = Int32(token), pid > 1 else {
            throw SessionError.agentStartFailed("无法解析 agent PID：\(out.isEmpty ? "空" : out)")
        }
        try? "\(pid)\n".write(to: agentPIDURL, atomically: true, encoding: .utf8)

        // Wait until agent loop is alive.
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if isPIDAlive(pid) { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw SessionError.agentStartFailed("agent 启动后立即退出，见 \(agentLogURL.path)")
    }

    /// Run a shell script as root via the agent (no password if agent already up).
    @discardableResult
    static func runRootScript(_ script: String, timeout: TimeInterval = 120) throws -> String {
        try ensureAgent()
        try prepareLayout()

        let id = UUID().uuidString
        let req = queueDir.appendingPathComponent("\(id).req")
        let tmp = queueDir.appendingPathComponent("\(id).req.tmp")
        let outURL = queueDir.appendingPathComponent("\(id).out")
        let statusURL = queueDir.appendingPathComponent("\(id).status")
        let doneURL = queueDir.appendingPathComponent("\(id).done")

        let body = "#!/bin/bash\nset -e\n" + script + "\n"
        try body.write(to: tmp, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tmp.path)
        // Atomic publish for agent watcher.
        try? FileManager.default.removeItem(at: req)
        try FileManager.default.moveItem(at: tmp, to: req)

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !isAgentRunning() {
                // One retry: relaunch agent (may prompt again if agent died).
                try ensureAgent()
            }
            if FileManager.default.fileExists(atPath: doneURL.path) {
                let statusText = (try? String(contentsOf: statusURL, encoding: .utf8))?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? "1"
                let code = Int(statusText) ?? 1
                let out = (try? String(contentsOf: outURL, encoding: .utf8)) ?? ""
                try? FileManager.default.removeItem(at: doneURL)
                try? FileManager.default.removeItem(at: outURL)
                try? FileManager.default.removeItem(at: statusURL)
                try? FileManager.default.removeItem(at: req)
                if code != 0 {
                    throw SessionError.commandFailed(code, out)
                }
                return out
            }
            Thread.sleep(forTimeInterval: 0.08)
        }
        try? FileManager.default.removeItem(at: req)
        throw SessionError.commandTimeout
    }

    /// Ask agent to stop (optional). Best-effort, no password if agent alive.
    static func shutdownAgent() {
        guard isAgentRunning() else {
            try? FileManager.default.removeItem(at: agentPIDURL)
            return
        }
        try? Data().write(to: quitFlagURL)
        // Give it a moment; do not prompt.
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if !isAgentRunning() { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        try? FileManager.default.removeItem(at: agentPIDURL)
    }

    // MARK: - Internals

    private static func prepareLayout() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: queueDir, withIntermediateDirectories: true)
        // User must be able to drop requests; agent (root) executes them.
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: rootDir.path)
        try? fm.setAttributes([.posixPermissions: 0o777], ofItemAtPath: queueDir.path)
    }

    private static func writeAgentScript() throws {
        let script = #"""
#!/bin/bash
# OpenZweb elevated agent — runs as root; executes user-queued scripts once.
set -u
BASE="$(cd "$(dirname "$0")" && pwd)"
QUEUE="$BASE/queue"
mkdir -p "$QUEUE"
chmod 777 "$QUEUE" 2>/dev/null || true
echo $$ > "$BASE/agent.pid"
echo "$(date '+%F %T') agent start pid=$$" >> "$BASE/agent.log"

cleanup_engine() {
  if [ -f "$BASE/engine.pid" ]; then
    ep=$(cat "$BASE/engine.pid" 2>/dev/null || true)
    if [ -n "${ep:-}" ]; then
      kill "$ep" 2>/dev/null || true
      sleep 0.2
      kill -9 "$ep" 2>/dev/null || true
    fi
    rm -f "$BASE/engine.pid"
  fi
}

while true; do
  if [ -f "$BASE/quit" ]; then
    rm -f "$BASE/quit"
    cleanup_engine
    echo "$(date '+%F %T') agent quit" >> "$BASE/agent.log"
    rm -f "$BASE/agent.pid"
    exit 0
  fi

  shopt -s nullglob
  for req in "$QUEUE"/*.req; do
    [ -f "$req" ] || continue
    id="$(basename "$req" .req)"
    out="$QUEUE/$id.out"
    st="$QUEUE/$id.status"
    donef="$QUEUE/$id.done"
    # Run without set -e so we always record status.
    /bin/bash "$req" >"$out" 2>&1
    echo $? >"$st"
    rm -f "$req"
    : >"$donef"
  done
  shopt -u nullglob
  sleep 0.12
done
"""#
        try script.write(to: agentScriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: agentScriptURL.path)
    }

    private static func runOsascriptAdmin(_ shellScript: String, timeout: TimeInterval) throws -> String {
        // Write shell to temp so AppleScript escaping stays simple.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("openzweb-elevated-\(UUID().uuidString).sh")
        try shellScript.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        defer { try? FileManager.default.removeItem(at: url) }

        let ascript = "do shell script \(asQuote("/bin/bash \(shQuote(url.path))")) with administrator privileges"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", ascript]
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()

        // Optional soft timeout: password dialog may take long; use generous timeout.
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            throw SessionError.commandTimeout
        }
        process.waitUntilExit()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        let outText = String(data: outData, encoding: .utf8) ?? ""
        let errText = String(data: errData, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            let msg = errText.trimmingCharacters(in: .whitespacesAndNewlines)
            throw SessionError.agentStartFailed(msg.isEmpty ? "osascript exit \(process.terminationStatus)" : msg)
        }
        return outText
    }

    private static func readPID(from url: URL) -> pid_t? {
        guard let s = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let v = Int32(t), v > 1 else { return nil }
        return v
    }

    static func isPIDAlive(_ pid: pid_t) -> Bool {
        if pid <= 1 { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    private static func shQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func asQuote(_ s: String) -> String {
        "\"" + s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
