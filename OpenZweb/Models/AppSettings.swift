import Foundation
import SwiftUI

enum VPNProtocolKind: String, CaseIterable, Identifiable, Codable {
    case atrust = "atrust"
    case easyconnect = "easyconnect"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .atrust: return L10n.t("proto.atrust")
        case .easyconnect: return L10n.t("proto.easyconnect")
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
        case .password: return L10n.t("auth.password")
        case .cas: return L10n.t("auth.cas")
        case .sms: return L10n.t("auth.sms")
        }
    }
}

enum ConnectionMode: String, CaseIterable, Identifiable, Codable {
    case proxy = "proxy"
    case tun = "tun"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .proxy: return L10n.t("conn.proxy_desc")
        case .tun: return L10n.t("conn.tun_desc")
        }
    }

    var detail: String {
        switch self {
        case .proxy:
            return L10n.t("conn.proxy_detail")
        case .tun:
            return L10n.t("conn.tun_detail")
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
    var preferSkipSecondaryAuth: Bool = true
    /// UI language; system follows macOS locale.
    var appLanguage: AppLanguage = .system

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
        case .idle: return L10n.t("phase.idle")
        case .preparing: return L10n.t("phase.preparing")
        case .authenticating: return L10n.t("phase.authenticating")
        case .waitingCaptcha: return L10n.t("phase.waiting_captcha")
        case .waitingSMS: return L10n.t("phase.waiting_sms")
        case .connecting: return L10n.t("phase.connecting")
        case .connected: return L10n.t("phase.connected")
        case .disconnecting: return L10n.t("phase.disconnecting")
        case .failed: return L10n.t("phase.failed")
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
