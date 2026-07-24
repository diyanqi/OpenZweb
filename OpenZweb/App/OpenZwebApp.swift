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
            CommandMenu("连接") {
                Button("断开连接") { engine.disconnect() }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                    .disabled(engine.phase == .idle)
                Divider()
                Button("复制 SOCKS5 地址") {
                    copy(store.settings.socksBind)
                }
                Button("复制 HTTP 代理地址") {
                    copy(store.settings.httpBind)
                }
                if store.settings.shareOnLAN {
                    Button("复制局域网代理信息") {
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

        MenuBarExtra {
            MenuBarMenu()
                .environmentObject(engine)
                .environmentObject(store)
                .environmentObject(updater)
        } label: {
            Image("BrandMark")
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 18, height: 18)
                .accessibilityLabel("OpenZweb")
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
            Button("显示主窗口") { showMain() }
            Button("检查更新") {
                Task { await updater.check(manual: true) }
            }
            if engine.phase == .connected {
                Button("复制 SOCKS5") { copy(store.settings.socksBind) }
                Button("复制 HTTP") { copy(store.settings.httpBind) }
                if store.settings.shareOnLAN {
                    Button("复制局域网代理信息") {
                        copy(ProxyHelper.lanSharePayload(
                            socksBind: store.settings.socksBind,
                            httpBind: store.settings.httpBind
                        ))
                    }
                }
                Divider()
                Button("打开浙大导航 zjuers.com") {
                    if let url = URL(string: "https://zjuers.com/") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Button("断开连接", role: .destructive) { engine.disconnect() }
            }
            Divider()
            Toggle("系统代理自动管理", isOn: $store.settings.manageSystemProxy)
            Toggle("局域网共享代理", isOn: $store.settings.shareOnLAN)
            Divider()
            Button("退出 OpenZweb") {
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
