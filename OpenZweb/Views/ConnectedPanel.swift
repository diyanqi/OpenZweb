import SwiftUI
import AppKit

struct ConnectedPanel: View {
    @EnvironmentObject private var engine: ConnectEngine
    @EnvironmentObject private var store: SettingsStore
    @EnvironmentObject private var monitor: NetworkMonitor
    @State private var now = Date()
    @State private var pacMessage: String?
    @State private var showLANShare = false

    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                header
                if store.settings.showNetworkMonitor {
                    monitorCard
                }
                endpointsCard
                portalCard
                if store.settings.shareOnLAN {
                    lanCard
                }
                actions
            }
            .padding(28)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .onReceive(ticker) { now = $0 }
        .sheet(isPresented: $showLANShare) {
            LANShareSheet()
                .environmentObject(store)
        }
    }

    private var header: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Color.green.opacity(0.35), Color.green.opacity(0.05)],
                            center: .center,
                            startRadius: 10,
                            endRadius: 70
                        )
                    )
                    .frame(width: 120, height: 120)
                Image(systemName: engine.activeMode == .tun ? "network.badge.shield.half.filled" : "checkmark.shield.fill")
                    .font(.system(size: 46, weight: .medium))
                    .foregroundStyle(.green)
                    .symbolRenderingMode(.hierarchical)
            }
            Text("已接入浙江大学内网")
                .font(.system(.title, design: .rounded).weight(.bold))
            Text("\(engine.activeMode.displayName) · 已连接 \(uptimeText)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 8)
    }

    private var monitorCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("实时吞吐", systemImage: "waveform.path.ecg")
                    .font(.headline)
                Spacer()
                Button {
                    Task {
                        await monitor.refreshIP(
                            httpProxy: store.settings.httpBind,
                            socksProxy: store.settings.socksBind
                        )
                    }
                } label: {
                    if monitor.isChecking {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("检测公网 IP", systemImage: "globe")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(monitor.isChecking)
            }

            HStack(spacing: 18) {
                ratePill(title: "下载", value: NetworkMonitor.formatRate(monitor.downBps), color: .accentColor)
                ratePill(title: "上传", value: NetworkMonitor.formatRate(monitor.upBps), color: .orange)
            }

            SparklineView(
                downs: monitor.samples.map(\.downBps),
                ups: monitor.samples.map(\.upBps)
            )
            .frame(height: 92)

            VStack(alignment: .leading, spacing: 6) {
                if let ip = monitor.publicIP {
                    HStack(alignment: .firstTextBaseline) {
                        Text("公网 IP")
                            .foregroundStyle(.secondary)
                        Text(ip)
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                    }
                    .font(.callout)
                }
                if let loc = monitor.publicIPLocation, !loc.isEmpty {
                    HStack(alignment: .firstTextBaseline) {
                        Text("归属地")
                            .foregroundStyle(.secondary)
                        Text(loc)
                            .textSelection(.enabled)
                    }
                    .font(.callout)
                }
                Text(monitor.lastCheckMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Text(NetworkMonitor.geoDisclaimer)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        )
    }

    private func ratePill(title: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .foregroundStyle(color)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var endpointsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("接入信息")
                .font(.headline)

            // Mode is fixed for this session — live TUN/proxy switch needs re-auth in zju-connect.
            infoRow("模式", engine.activeMode == .tun ? "TUN 虚拟网卡" : "代理 (SOCKS5 / HTTP)")
            if engine.activeMode == .tun {
                Text("系统级虚拟网卡；如需改为代理模式，请断开后在登录页切换再连接。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("应用通过本机 SOCKS/HTTP 代理访问内网；如需 TUN，请断开后在登录页切换。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            infoRow("SOCKS5", effectiveSocks)
            infoRow("HTTP", effectiveHTTP)
            if let msg = pacMessage {
                Text(msg).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var effectiveSocks: String {
        store.settings.shareOnLAN
            ? ProxyHelper.lanBind(from: store.settings.socksBind)
            : store.settings.socksBind
    }

    private var effectiveHTTP: String {
        store.settings.shareOnLAN
            ? ProxyHelper.lanBind(from: store.settings.httpBind)
            : store.settings.httpBind
    }

    private var lanCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("局域网共享", systemImage: "antenna.radiowaves.left.and.right")
                .font(.headline)
            if let ip = ProxyHelper.primaryLANAddress() {
                infoRow("本机局域网 IP", ip)
            } else {
                Text("未检测到局域网地址")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            infoRow("SOCKS5", effectiveSocks)
            infoRow("HTTP", effectiveHTTP)
            Text("其他设备请在同一网络下，将系统/App 代理指向上述地址与端口。二维码仅为纯文本，无法自动改系统设置，故仅展示连接信息。")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Button("显示连接信息") { showLANShare = true }
                .buttonStyle(.bordered)
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var portalCard: some View {
        HStack(spacing: 14) {
            Image(systemName: "map.fill")
                .font(.title2)
                .foregroundStyle(Color(red: 0.78, green: 0.18, blue: 0.22))
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 4) {
                Text("浙大导航")
                    .font(.headline)
                Text("常用校内站点入口 · zjuers.com")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("前往导航页") {
                if let url = URL(string: "https://zjuers.com/") {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var actions: some View {
        HStack(spacing: 12) {
            Button {
                do {
                    let url = try ProxyHelper.savePAC(
                        httpProxy: store.settings.httpBind,
                        socksProxy: store.settings.socksBind,
                        allowList: store.settings.proxyAllowDomains,
                        denyList: store.settings.proxyDenyDomains
                    )
                    ProxyHelper.revealInFinder(url)
                    pacMessage = "已导出 PAC"
                } catch {
                    pacMessage = error.localizedDescription
                }
            } label: {
                Label("导出 PAC", systemImage: "doc.badge.gearshape")
            }
            .buttonStyle(.bordered)

            Button(role: .destructive) {
                engine.disconnect()
            } label: {
                Label("断开连接", systemImage: "xmark.circle")
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
        }
        .padding(.bottom, 12)
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.body.monospaced())
                .textSelection(.enabled)
        }
        .font(.callout)
    }

    private var uptimeText: String {
        guard let since = engine.connectedSince else { return "—" }
        let s = Int(now.timeIntervalSince(since))
        let h = s / 3600
        let m = (s % 3600) / 60
        let sec = s % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, sec) }
        return String(format: "%02d:%02d", m, sec)
    }
}

struct LANShareSheet: View {
    @EnvironmentObject private var store: SettingsStore
    @Environment(\.dismiss) private var dismiss

    private var payload: String {
        ProxyHelper.lanSharePayload(
            socksBind: store.settings.socksBind,
            httpBind: store.settings.httpBind
        )
    }

    var body: some View {
        VStack(spacing: 18) {
            Text("局域网代理连接信息")
                .font(.title2.weight(.semibold))
            Text("请在其他设备上手动填写下列代理。需与本机同一 Wi‑Fi，并允许 macOS 防火墙通过。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            Text(payload)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))

            HStack {
                Button("复制全部") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(payload, forType: .string)
                }
                Button("完成") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 420)
    }
}
