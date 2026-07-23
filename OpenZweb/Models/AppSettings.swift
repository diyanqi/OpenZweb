import Foundation
import SwiftUI

enum VPNProtocolKind: String, CaseIterable, Identifiable, Codable {
    case atrust = "atrust"
    case easyconnect = "easyconnect"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .atrust: return "aTrust"
        case .easyconnect: return "EasyConnect"
        }
    }
}

enum AuthMethod: String, CaseIterable, Identifiable, Codable {
    case password = "auth/psw"
    case cas = "auth/cas"
    case sms = "auth/smsCheckCode"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .password: return "学号密码"
        case .cas: return "统一身份认证 (CAS)"
        case .sms: return "短信验证码"
        }
    }
}

enum ConnectionMode: String, CaseIterable, Identifiable, Codable {
    case proxy = "proxy"
    case tun = "tun"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .proxy: return "代理模式 (SOCKS5/HTTP)"
        case .tun: return "TUN 全局虚拟网卡"
        }
    }

    var detail: String {
        switch self {
        case .proxy:
            return "无需管理员权限，应用自行配置代理即可访问内网。"
        case .tun:
            return "系统级路由，全应用可直连内网。需要输入管理员密码。"
        }
    }
}

struct AppSettings: Codable, Equatable {
    var serverAddress: String = "vpn.zju.edu.cn"
    var serverPort: Int = 443
    var protocolKind: VPNProtocolKind = .atrust
    var authMethod: AuthMethod = .password
    var loginDomain: String = "Radius"
    var username: String = ""
    var rememberPassword: Bool = true
    var connectionMode: ConnectionMode = .proxy
    var socksBind: String = "127.0.0.1:1080"
    var httpBind: String = "127.0.0.1:1081"
    var zjuDnsServer: String = "10.10.0.21"
    var secondaryDnsServer: String = "114.114.114.114"
    var disableServerConfig: Bool = true
    var disableKeepAlive: Bool = false
    var skipDomainResource: Bool = false
    var debugMode: Bool = false
    var zjuDns: Bool = false
    var autoReconnect: Bool = true
    /// When connected in proxy mode, set macOS system HTTP/HTTPS/SOCKS proxy and restore on disconnect.
    var manageSystemProxy: Bool = true
    /// Push ZJU DNS into system resolvers while connected (helps Safari resolve campus domains).
    var manageSystemDNS: Bool = true
    /// Bind SOCKS/HTTP on 0.0.0.0 so other LAN devices can use this Mac as proxy.
    var shareOnLAN: Bool = false
    /// Show live throughput chart + IP tools on connected dashboard.
    var showNetworkMonitor: Bool = true
    /// Compact UI density
    var compactUI: Bool = false
    var addRoute: Bool = true
    var dnsHijack: Bool = true
    var dnsAutoSetup: Bool = true
    var fakeIP: Bool = false
    var tcpTunnelMode: Bool = false
    var launchAtLogin: Bool = false
    var showInMenuBar: Bool = true
    var showInDock: Bool = true
    /// Domains forced through RVPN (zju-connect custom_proxy_domain). One per line or comma-separated.
    var proxyAllowList: String = ""
    /// Domains that should bypass VPN in PAC / system proxy routing. One per line or comma-separated.
    var proxyDenyList: String = ""
    /// Auto-check for new releases at launch.
    var checkUpdatesOnLaunch: Bool = true
    /// Default: check skip future secondary SMS (prefix $).
    var preferSkipSecondaryAuth: Bool = false

    // Legacy migration
    var dnsServer: String? = nil

    static let storageKey = "openzweb.settings"
    static let defaults = AppSettings()

    var tunMode: Bool { connectionMode == .tun }

    /// Split allow/deny text into clean domain tokens.
    static func parseDomainList(_ raw: String) -> [String] {
        let normalized = raw
            .replacingOccurrences(of: ",", with: "\n")
            .replacingOccurrences(of: ";", with: "\n")
        return normalized
            .split(whereSeparator: { $0.isNewline || $0.isWhitespace })
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .map { token -> String in
                var t = token.lowercased()
                if t.hasPrefix("*.") { t = String(t.dropFirst(2)) }
                if t.hasPrefix(".") { t = String(t.dropFirst()) }
                if t.hasPrefix("http://") { t = String(t.dropFirst(7)) }
                if t.hasPrefix("https://") { t = String(t.dropFirst(8)) }
                if let slash = t.firstIndex(of: "/") { t = String(t[..<slash]) }
                return t
            }
            .filter { !$0.isEmpty }
    }

    var proxyAllowDomains: [String] { Self.parseDomainList(proxyAllowList) }
    var proxyDenyDomains: [String] { Self.parseDomainList(proxyDenyList) }

    static func load() -> AppSettings {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              var decoded = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return .defaults
        }
        if decoded.zjuDnsServer.isEmpty, let legacy = decoded.dnsServer, !legacy.isEmpty {
            decoded.zjuDnsServer = legacy
        }
        // ZJU portal host moved from rvpn.zju.edu.cn → vpn.zju.edu.cn
        if decoded.serverAddress == "rvpn.zju.edu.cn" {
            decoded.serverAddress = "vpn.zju.edu.cn"
        }
        return decoded
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }
}

enum ConnectionPhase: Equatable {
    case idle
    case preparing
    case authenticating
    case waitingCaptcha
    case waitingSMS
    case connecting
    case connected
    case disconnecting
    case failed(String)

    var title: String {
        switch self {
        case .idle: return "未连接"
        case .preparing: return "准备中"
        case .authenticating: return "正在认证"
        case .waitingCaptcha: return "等待验证码"
        case .waitingSMS: return "等待短信验证码"
        case .connecting: return "正在建立隧道"
        case .connected: return "已连接"
        case .disconnecting: return "正在断开"
        case .failed: return "连接失败"
        }
    }

    var isBusy: Bool {
        switch self {
        case .preparing, .authenticating, .waitingCaptcha, .waitingSMS, .connecting, .disconnecting:
            return true
        default:
            return false
        }
    }
}
