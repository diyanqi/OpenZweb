import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject private var engine: ConnectEngine
    @EnvironmentObject private var store: SettingsStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section(L10n.t("settings.server")) {
                    TextField(L10n.t("settings.address"), text: $store.settings.serverAddress)
                    TextField(L10n.t("settings.port"), value: $store.settings.serverPort, format: .number)
                    Picker(L10n.t("settings.protocol"), selection: $store.settings.protocolKind) {
                        ForEach(VPNProtocolKind.allCases) { Text($0.displayName).tag($0) }
                    }
                    Picker(L10n.t("settings.auth"), selection: $store.settings.authMethod) {
                        ForEach(AuthMethod.allCases) { Text($0.displayName).tag($0) }
                    }
                    TextField(L10n.t("settings.login_domain"), text: $store.settings.loginDomain)
                }

                Section(L10n.t("settings.connection")) {
                    Picker(L10n.t("settings.mode"), selection: $store.settings.connectionMode) {
                        ForEach(ConnectionMode.allCases) { Text($0.displayName).tag($0) }
                    }
                    TextField(L10n.t("settings.socks5"), text: $store.settings.socksBind)
                    TextField(L10n.t("settings.http"), text: $store.settings.httpBind)
                    Toggle(L10n.t("settings.share_lan"), isOn: $store.settings.shareOnLAN)
                    Toggle(L10n.t("settings.manage_proxy"), isOn: $store.settings.manageSystemProxy)
                    Text(store.settings.manageSystemProxy
                         ? L10n.t("settings.manage_proxy_on")
                         : L10n.t("settings.manage_proxy_off"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Toggle(L10n.t("settings.auto_reconnect"), isOn: $store.settings.autoReconnect)
                    Toggle(L10n.t("settings.prefer_skip_sms"), isOn: $store.settings.preferSkipSecondaryAuth)
                    Text(L10n.t("settings.prefer_skip_sms_hint"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section(L10n.t("settings.advanced")) {
                    Toggle(L10n.t("settings.fake_ip"), isOn: $store.settings.fakeIP)
                    Toggle(L10n.t("settings.tcp_tunnel"), isOn: $store.settings.tcpTunnelMode)
                    Toggle(L10n.t("settings.skip_domain"), isOn: $store.settings.skipDomainResource)
                    Toggle(L10n.t("settings.debug"), isOn: $store.settings.debugMode)
                }

                Section(L10n.t("common.language")) {
                    Text(L10n.t("settings.language_hint"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker(L10n.t("settings.language"), selection: $store.settings.appLanguage) {
                        ForEach(AppLanguage.allCases) { lang in
                            Text(lang.displayName).tag(lang)
                        }
                    }
                    .onChange(of: store.settings.appLanguage) { _, lang in
                        LanguageController.shared.apply(lang)
                        store.persist()
                    }
                }

                Section(L10n.t("settings.ui")) {
                    Toggle(L10n.t("settings.show_monitor"), isOn: $store.settings.showNetworkMonitor)
                    Toggle(L10n.t("settings.compact"), isOn: $store.settings.compactUI)
                    Toggle(L10n.t("settings.launch_login"), isOn: $store.settings.launchAtLogin)
                        .onChange(of: store.settings.launchAtLogin) { _, v in
                            LaunchAtLogin.isEnabled = v
                        }
                    Toggle(L10n.t("settings.show_dock"), isOn: $store.settings.showInDock)
                        .onChange(of: store.settings.showInDock) { _, v in
                            if let delegate = NSApp.delegate as? AppDelegate {
                                // If main window is open, apply immediately; if tray-only, stay accessory.
                                delegate.reconcileDockWithOpenWindows()
                            } else {
                                NSApp.setActivationPolicy(v ? .regular : .accessory)
                            }
                        }
                    Text(L10n.t("settings.show_dock_hint"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Toggle(L10n.t("settings.check_updates_launch"), isOn: $store.settings.checkUpdatesOnLaunch)
                }

                Section(L10n.t("settings.updates")) {
                    UpdateSettingsRow()
                }

                Section(L10n.t("settings.engine")) {
                    LabeledContent(L10n.t("settings.path")) {
                        Text(engine.coreBinaryPath ?? L10n.t("settings.not_installed"))
                            .font(.caption.monospaced())
                            .lineLimit(3)
                            .textSelection(.enabled)
                    }
                    HStack {
                        Button(L10n.t("proxy.recheck")) { engine.refreshCoreBinary() }
                        Button {
                            Task { await engine.downloadCore() }
                        } label: {
                            if engine.isDownloadingCore {
                                ProgressView().controlSize(.small)
                            } else {
                                Text(engine.coreBinaryPath == nil ? "下载引擎" : "重新下载")
                            }
                        }
                        .disabled(engine.isDownloadingCore)
                    }
                    if let note = engine.coreBinaryNote {
                        Text(note).font(.caption).foregroundStyle(.orange)
                    }
                }

                Section(L10n.t("settings.zju_preset")) {
                    Button(L10n.t("settings.restore_zju")) {
                        store.applyZJUDefaults()
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button(L10n.t("common.done")) {
                    store.persist()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .frame(minWidth: 560, minHeight: 600)
    }
}


private struct UpdateSettingsRow: View {
    @EnvironmentObject private var updater: UpdateChecker

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L10n.t("settings.current_version"))
                Spacer()
                Text(updater.currentVersion)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if let latest = updater.latestVersion {
                HStack {
                    Text(L10n.t("settings.latest_version"))
                    Spacer()
                    Text(latest)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            if let msg = updater.statusMessage {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(updater.hasUpdate ? Color.orange : Color.secondary)
            }
            HStack {
                Button(updater.isChecking ? "检查中…" : "检查更新") {
                    Task { await updater.check(manual: true) }
                }
                .disabled(updater.isChecking)
                if updater.hasUpdate, let url = updater.releaseURL {
                    Button(L10n.t("settings.open_release")) {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }
}
