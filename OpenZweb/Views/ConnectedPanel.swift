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
                BrandMarkTapView(size: 48, cornerRadius: 12)
            }
            Text(L10n.t("connected.title"))
                .font(.system(.title, design: .rounded).weight(.bold))
            Text(L10n.format("connected.uptime", engine.activeMode.displayName, uptimeText))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 8)
    }

    private var monitorCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(L10n.t("connected.throughput"), systemImage: "waveform.path.ecg")
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
                        Label(L10n.t("connected.check_ip"), systemImage: "globe")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(monitor.isChecking)
            }

            HStack(spacing: 18) {
                ratePill(title: L10n.t("connected.download"), value: NetworkMonitor.formatRate(monitor.downBps), color: .accentColor)
                ratePill(title: L10n.t("connected.upload"), value: NetworkMonitor.formatRate(monitor.upBps), color: .orange)
            }

            SparklineView(
                downs: monitor.samples.map(\.downBps),
                ups: monitor.samples.map(\.upBps)
            )
            .frame(height: 92)

            VStack(alignment: .leading, spacing: 6) {
                if let ip = monitor.publicIP {
                    HStack(alignment: .firstTextBaseline) {
                        Text(L10n.t("connected.public_ip"))
                            .foregroundStyle(.secondary)
                        Text(ip)
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                    }
                    .font(.callout)
                }
                if let loc = monitor.publicIPLocation, !loc.isEmpty {
                    HStack(alignment: .firstTextBaseline) {
                        Text(L10n.t("connected.geo"))
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
                Text(L10n.t("connected.geo_disclaimer"))
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
            Text(L10n.t("connected.info"))
                .font(.headline)

            // Mode is fixed for this session — live TUN/proxy switch needs re-auth in zju-connect.
            infoRow(L10n.t("sidebar.mode"), engine.activeMode == .tun ? L10n.t("mode.tun_full") : L10n.t("mode.proxy_socks_http"))
            if engine.activeMode == .tun {
                Text(L10n.t("connected.mode_tun_hint"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text(L10n.t("connected.mode_proxy_hint"))
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
            Label(L10n.t("connected.lan_share"), systemImage: "antenna.radiowaves.left.and.right")
                .font(.headline)
            if let ip = ProxyHelper.primaryLANAddress() {
                infoRow(L10n.t("connected.lan_ip"), ip)
            } else {
                Text(L10n.t("connected.lan_none"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            infoRow("SOCKS5", effectiveSocks)
            infoRow("HTTP", effectiveHTTP)
            Text(L10n.t("connected.lan_hint"))
                .font(.caption2)
                .foregroundStyle(.secondary)
            Button(L10n.t("connected.lan_show")) { showLANShare = true }
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
                Text(L10n.t("connected.nav_title"))
                    .font(.headline)
                Text(L10n.t("connected.nav_sub"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(L10n.t("connected.nav_go")) {
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
                    pacMessage = L10n.t("connected.pac_exported")
                } catch {
                    pacMessage = error.localizedDescription
                }
            } label: {
                Label(L10n.t("connected.export_pac"), systemImage: "doc.badge.gearshape")
            }
            .buttonStyle(.bordered)

            Button(role: .destructive) {
                engine.disconnect()
            } label: {
                Label(L10n.t("connected.disconnect"), systemImage: "xmark.circle")
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
            Text(L10n.t("connected.lan_sheet_title"))
                .font(.title2.weight(.semibold))
            Text(L10n.t("connected.lan_sheet_hint"))
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
                Button(L10n.t("connected.copy_all")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(payload, forType: .string)
                }
                Button(L10n.t("common.done")) { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 420)
    }
}
