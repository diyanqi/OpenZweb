import SwiftUI
import AppKit

@main
struct OpenZwebApp: App {
    @StateObject private var engine = ConnectEngine()
    @StateObject private var store = SettingsStore()
    @StateObject private var updater = UpdateChecker()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("OpenZweb") {
            ContentView()
                .environmentObject(engine)
                .environmentObject(store)
                .environmentObject(updater)
                .onAppear {
                    appDelegate.engine = engine
                    appDelegate.store = store
                    LaunchAtLogin.isEnabled = store.settings.launchAtLogin
                    engine.refreshCoreBinary()
                    Task { await updater.checkOnLaunchIfNeeded(enabled: store.settings.checkUpdatesOnLaunch) }
                }
        }
        .defaultSize(width: 960, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu(L10n.t("menu.connect")) {
                Button(L10n.t("menu.disconnect")) { engine.disconnect() }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                    .disabled(engine.phase == .idle)
                Divider()
                Button(L10n.t("menu.copy_socks")) {
                    copy(store.settings.socksBind)
                }
                Button(L10n.t("menu.copy_http")) {
                    copy(store.settings.httpBind)
                }
                if store.settings.shareOnLAN {
                    Button(L10n.t("menu.copy_lan")) {
                        copy(ProxyHelper.lanSharePayload(
                            socksBind: store.settings.socksBind,
                            httpBind: store.settings.httpBind
                        ))
                    }
                }
            }
        }

        Settings {
            SettingsView()
                .environmentObject(engine)
                .environmentObject(store)
                .environmentObject(updater)
                .frame(width: 560, height: 620)
        }

        // Menu bar keeps compact SF Symbols (not the full app icon).
        MenuBarExtra("OpenZweb", systemImage: menuBarSymbol) {
            MenuBarMenu()
                .environmentObject(engine)
                .environmentObject(store)
                .environmentObject(updater)
        }
    }

    private var menuBarSymbol: String {
        switch engine.phase {
        case .connected: return "shield.checkered"
        case .failed: return "shield.slash"
        case .waitingCaptcha, .waitingSMS: return "shield.lefthalf.filled"
        default: return "shield.lefthalf.filled"
        }
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var engine: ConnectEngine?
    weak var store: SettingsStore?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        Task { @MainActor in
            engine?.disconnect()
        }
    }
}

struct MenuBarMenu: View {
    @EnvironmentObject private var engine: ConnectEngine
    @EnvironmentObject private var store: SettingsStore
    @EnvironmentObject private var updater: UpdateChecker

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(engine.phase.title).font(.headline)
            if engine.phase == .connected {
                Text(engine.activeMode.displayName).font(.caption)
                Text("SOCKS \(store.settings.socksBind)").font(.caption.monospaced())
                Text("HTTP  \(store.settings.httpBind)").font(.caption.monospaced())
                if store.settings.shareOnLAN, let ip = ProxyHelper.primaryLANAddress() {
                    Text("LAN \(ip)").font(.caption.monospaced())
                }
            }

            Divider()
            Button(L10n.t("menu.show_main")) { showMain() }
            Button(L10n.t("menu.check_update")) {
                Task { await updater.check(manual: true) }
            }
            if engine.phase == .connected {
                Button(L10n.t("menu.copy_socks_short")) { copy(store.settings.socksBind) }
                Button(L10n.t("menu.copy_http_short")) { copy(store.settings.httpBind) }
                if store.settings.shareOnLAN {
                    Button(L10n.t("menu.copy_lan")) {
                        copy(ProxyHelper.lanSharePayload(
                            socksBind: store.settings.socksBind,
                            httpBind: store.settings.httpBind
                        ))
                    }
                }
                Divider()
                Button(L10n.t("menu.open_nav")) {
                    if let url = URL(string: "https://zjuers.com/") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Button(L10n.t("menu.disconnect"), role: .destructive) { engine.disconnect() }
            }
            Divider()
            Toggle(L10n.t("menu.manage_proxy"), isOn: $store.settings.manageSystemProxy)
            Toggle(L10n.t("menu.share_lan"), isOn: $store.settings.shareOnLAN)
            Divider()
            Button(L10n.t("menu.quit")) {
                engine.disconnect()
                NSApp.terminate(nil)
            }
        }
    }

    private func showMain() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first?.makeKeyAndOrderFront(nil)
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}
