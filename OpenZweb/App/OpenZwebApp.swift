import SwiftUI
import AppKit

@main
struct OpenZwebApp: App {
    @StateObject private var engine = ConnectEngine()
    @StateObject private var store = SettingsStore()
    @StateObject private var updater = UpdateChecker()
    @StateObject private var eggs = EasterEggController()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .environmentObject(engine)
                .environmentObject(store)
                .environmentObject(updater)
                .environmentObject(eggs)
                .onAppear {
                    appDelegate.engine = engine
                    appDelegate.store = store
                    appDelegate.applyDockVisibility(showDock: store.settings.showInDock)
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
                .environmentObject(eggs)
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

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var engine: ConnectEngine?
    weak var store: SettingsStore?

    private var windowCloseObserver: NSObjectProtocol?
    private var windowOpenObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Closing the last window must NOT quit — keep menu bar agent alive.
        // (Also implemented via applicationShouldTerminateAfterLastWindowClosed.)
        windowCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            // Ignore non-app panels / status items.
            guard let window = note.object as? NSWindow else { return }
            guard window.isVisible || window.isKeyWindow || window.isMainWindow else { return }
            // Delay until after the window is actually gone from NSApp.windows.
            DispatchQueue.main.async {
                self.reconcileDockWithOpenWindows()
            }
        }
        windowOpenObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reconcileDockWithOpenWindows()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let windowCloseObserver {
            NotificationCenter.default.removeObserver(windowCloseObserver)
        }
        if let windowOpenObserver {
            NotificationCenter.default.removeObserver(windowOpenObserver)
        }
        Task { @MainActor in
            engine?.disconnect()
        }
    }

    /// Keep process alive when user closes the main window (menu bar stays).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Dock icon click while running as accessory / hidden main window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            showMainWindow()
        }
        return true
    }

    /// Hide Dock when main window is gone; keep menu-bar process running.
    func reconcileDockWithOpenWindows() {
        let preferDock = store?.settings.showInDock ?? true
        let hasMain = Self.hasVisibleMainWindow()
        // Closed main window → always leave Dock (tray-only). Open window → honor setting.
        applyDockVisibility(showDock: hasMain && preferDock)
    }

    func applyDockVisibility(showDock: Bool) {
        let policy: NSApplication.ActivationPolicy = showDock ? .regular : .accessory
        if NSApp.activationPolicy() != policy {
            NSApp.setActivationPolicy(policy)
        }
    }

    func showMainWindow() {
        let preferDock = store?.settings.showInDock ?? true
        // Need .regular briefly so windows can become key, even if user hides Dock later.
        applyDockVisibility(showDock: true) // temporary .regular so window can key
        NSApp.activate(ignoringOtherApps: true)

        if let window = Self.mainWindows().first {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            applyDockVisibility(showDock: preferDock)
            return
        }

        // Fallback: reopen own bundle to recreate WindowGroup if all windows were destroyed.
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in
            DispatchQueue.main.async {
                Self.mainWindows().first?.makeKeyAndOrderFront(nil)
                self.applyDockVisibility(showDock: preferDock)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            Self.mainWindows().first?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            self.applyDockVisibility(showDock: preferDock)
        }
    }

    private static func hasVisibleMainWindow() -> Bool {
        mainWindows().contains { $0.isVisible && !$0.isMiniaturized }
    }

    private static func mainWindows() -> [NSWindow] {
        NSApp.windows.filter { window in
            // Exclude status-item / menu-bar-extra chrome and closed panels.
            guard window.canBecomeMain || window.canBecomeKey else { return false }
            let className = String(describing: type(of: window))
            if className.contains("StatusBar") || className.contains("MenuBar") { return false }
            // Settings window is ok to count as UI, but dock hide only when NOTHING left.
            return true
        }
    }
}

struct MenuBarMenu: View {
    @EnvironmentObject private var engine: ConnectEngine
    @EnvironmentObject private var store: SettingsStore
    @EnvironmentObject private var updater: UpdateChecker
    @Environment(\.openWindow) private var openWindow

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
        if let delegate = NSApp.delegate as? AppDelegate {
            // Prefer AppDelegate path (restores Dock + focuses/opens window).
            openWindow(id: "main")
            delegate.showMainWindow()
            return
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "main")
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}
