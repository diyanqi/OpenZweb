import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject private var engine: ConnectEngine
    @EnvironmentObject private var store: SettingsStore
    @EnvironmentObject private var updater: UpdateChecker
    @EnvironmentObject private var eggs: EasterEggController
    @StateObject private var monitor = NetworkMonitor()
    @State private var password: String = ""
    @State private var showSettings = false
    @State private var showLogs = false
    @State private var showAbout = false
    @State private var showRoutingRules = false

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 228, ideal: 248, max: 300)
        } detail: {
            detail
                .background(DetailBackground())
        }
        .frame(minWidth: 860, minHeight: 680)
        .alert(L10n.t("update.found"), isPresented: Binding(
            get: { updater.hasUpdate && !updater.bannerDismissed },
            set: { if !$0 { updater.clearBanner() } }
        )) {
            if let url = updater.releaseURL {
                Button(L10n.t("update.view")) { NSWorkspace.shared.open(url) }
            }
            Button(L10n.t("common.later"), role: .cancel) { updater.clearBanner() }
        } message: {
            Text(updater.statusMessage ?? "")
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(engine)
                .environmentObject(store)
                .environmentObject(updater)
                .frame(width: 580, height: 720)
        }
        .sheet(isPresented: $showLogs) {
            LogView()
                .environmentObject(engine)
                .frame(width: 760, height: 500)
        }
        .sheet(isPresented: $showAbout) {
            AboutView()
                .environmentObject(eggs)
        }
        .sheet(isPresented: Binding(
            get: { eggs.showPlayer },
            set: { if !$0 { eggs.showPlayer = false } }
        )) {
            EasterEggPlayerSheet()
                .environmentObject(eggs)
        }
        .sheet(isPresented: $showRoutingRules) {
            RoutingRulesView()
                .environmentObject(store)
                .environmentObject(engine)
        }
        .sheet(isPresented: smsPresented) {
            SMSOTPSheet()
                .environmentObject(engine)
        }
        .alert(
            L10n.t("phase.failed"),
            isPresented: Binding(
                get: { engine.failureDialogMessage != nil },
                set: { present in
                    if !present { engine.dismissFailureDialog() }
                }
            )
        ) {
            Button(L10n.t("common.ok"), role: .cancel) {
                engine.dismissFailureDialog()
            }
        } message: {
            Text(engine.failureDialogMessage ?? "")
        }
        .alert(
            engine.proxyConflict?.title ?? L10n.t("proxy.conflict_title"),
            isPresented: Binding(
                get: { engine.proxyConflict != nil },
                set: { present in
                    // Dismiss (Esc / outside) only closes the sheet; does not auto-connect.
                    if !present { engine.dismissProxyConflictWarning() }
                }
            )
        ) {
            Button(L10n.t("proxy.recheck")) {
                engine.recheckProxyConflictAndContinue()
            }
            Button(L10n.t("proxy.connect_anyway")) {
                engine.continueDespiteProxyConflict()
            }
            Button(L10n.t("common.cancel"), role: .cancel) {
                engine.dismissProxyConflictWarning()
            }
        } message: {
            Text(engine.proxyConflict?.detail ?? "")
        }
        .onAppear {
            if password.isEmpty,
               !store.settings.username.isEmpty,
               let saved = CredentialStore.loadPassword(account: store.settings.username) {
                password = saved
            }
        }
        .onChange(of: store.settings.username) { _, newValue in
            if let saved = CredentialStore.loadPassword(account: newValue) {
                password = saved
            }
        }
        .onChange(of: engine.phase) { _, phase in
            if phase == .connected, store.settings.showNetworkMonitor {
                monitor.start()
                Task {
                    await monitor.refreshIP(
                        httpProxy: store.settings.httpBind,
                        socksProxy: store.settings.socksBind
                    )
                }
            } else if phase != .connected {
                monitor.stop()
            }
        }
        .environmentObject(monitor)
    }

    private var smsPresented: Binding<Bool> {
        Binding(
            get: {
                if engine.holdSMSSheet { return true }
                if case .waitingSMS = engine.phase { return true }
                return false
            },
            set: { present in
                if !present {
                    // User closed OTP sheet — cancel the whole connect attempt.
                    if engine.holdSMSSheet || {
                        if case .waitingSMS = engine.phase { return true }
                        return false
                    }() {
                        engine.disconnect()
                    }
                }
            }
        )
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    BrandMarkTapView(size: 44, cornerRadius: 12)
                            .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text("OpenZweb")
                            .font(.system(.title3, design: .rounded).weight(.bold))
                        Text("ZJU · aTrust")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                StatusBadge(phase: engine.phase)
            }
            .padding(18)

            Divider().opacity(0.45)

            VStack(alignment: .leading, spacing: 16) {
                metaBlock(title: L10n.t("sidebar.protocol"), value: store.settings.protocolKind.displayName, icon: "lock.shield")
                metaBlock(
                    title: L10n.t("sidebar.mode"),
                    value: store.settings.connectionMode == .tun ? L10n.t("mode.tun_global") : L10n.t("mode.proxy"),
                    icon: "network"
                )
                metaBlock(
                    title: L10n.t("sidebar.server"),
                    value: "\(store.settings.serverAddress):\(store.settings.serverPort)",
                    icon: "server.rack"
                )

                if engine.phase == .connected {
                    if engine.activeMode == .tun {
                        metaBlock(title: L10n.t("sidebar.channel"), value: L10n.t("sidebar.tun_iface"), icon: "network.badge.shield.half.filled")
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            Label(L10n.t("sidebar.local_proxy"), systemImage: "point.3.connected.trianglepath.dotted")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text("SOCKS  \(effectiveSocks)")
                            Text("HTTP   \(effectiveHTTP)")
                        }
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                    }

                    if store.settings.shareOnLAN, let lan = ProxyHelper.primaryLANAddress() {
                        metaBlock(title: L10n.t("sidebar.lan"), value: lan, icon: "wifi.router")
                    }
                }
            }
            .padding(18)

            Spacer(minLength: 8)

            VStack(spacing: 8) {
                sidebarButton(L10n.t("sidebar.logs"), icon: "list.bullet.rectangle") { showLogs = true }
                sidebarButton(L10n.t("sidebar.routing"), icon: "arrow.triangle.branch") { showRoutingRules = true }
                sidebarButton(L10n.t("sidebar.settings"), icon: "gearshape") { showSettings = true }
                sidebarButton(L10n.t("sidebar.about"), icon: "info.circle") { showAbout = true }
            }
            .padding(16)
        }
        .background(.ultraThinMaterial)
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

    private func metaBlock(title: String, value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.body.weight(.medium))
                .textSelection(.enabled)
        }
    }

    private func sidebarButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Label(title, systemImage: icon)
                    .labelStyle(.titleAndIcon)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .controlSize(.regular)
    }

    @ViewBuilder
    private var detail: some View {
        switch engine.phase {
        case .connected:
            ConnectedPanel()
                .environmentObject(engine)
                .environmentObject(store)
                .environmentObject(monitor)
        case .waitingCaptcha:
            CaptchaPanel(password: $password)
                .environmentObject(engine)
                .environmentObject(store)
        default:
            LoginPanel(password: $password)
                .environmentObject(engine)
                .environmentObject(store)
        }
    }
}

struct DetailBackground: View {
    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            LinearGradient(
                colors: [
                    Color(red: 0.78, green: 0.18, blue: 0.22).opacity(0.08),
                    Color.clear,
                    Color.accentColor.opacity(0.05)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .ignoresSafeArea()
    }
}

struct StatusBadge: View {
    let phase: ConnectionPhase

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .shadow(color: color.opacity(0.7), radius: 4)
            Text(phase.title)
                .font(.subheadline.weight(.semibold))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(color.opacity(0.12), in: Capsule())
    }

    private var color: Color {
        switch phase {
        case .connected: return .green
        case .failed: return .red
        case .idle: return .secondary
        case .waitingCaptcha, .waitingSMS: return .orange
        default: return .blue
        }
    }
}
