import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject private var engine: ConnectEngine
    @EnvironmentObject private var store: SettingsStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("服务器") {
                    TextField("地址", text: $store.settings.serverAddress)
                    TextField("端口", value: $store.settings.serverPort, format: .number)
                    Picker("协议", selection: $store.settings.protocolKind) {
                        ForEach(VPNProtocolKind.allCases) { Text($0.displayName).tag($0) }
                    }
                    Picker("认证", selection: $store.settings.authMethod) {
                        ForEach(AuthMethod.allCases) { Text($0.displayName).tag($0) }
                    }
                    TextField("登录域", text: $store.settings.loginDomain)
                }

                Section("连接") {
                    Picker("模式", selection: $store.settings.connectionMode) {
                        ForEach(ConnectionMode.allCases) { Text($0.displayName).tag($0) }
                    }
                    TextField("SOCKS5", text: $store.settings.socksBind)
                    TextField("HTTP", text: $store.settings.httpBind)
                    Toggle("向局域网共享代理 (0.0.0.0)", isOn: $store.settings.shareOnLAN)
                    Toggle("连接后自动设置系统代理", isOn: $store.settings.manageSystemProxy)
                    Text(store.settings.manageSystemProxy
                         ? "会占用系统 HTTP/SOCKS 代理。若已开 Clash 等，请先关闭其系统代理，或关闭本选项以共存。"
                         : "不修改系统代理，可与 Clash 等共存。请在 Clash 将 *.zju.edu.cn / cc98.org 等校内域名指向本机 SOCKS（默认 127.0.0.1:1080），并为 vpn.zju.edu.cn 设置直连。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Toggle("断线自动重连", isOn: $store.settings.autoReconnect)
                    Toggle("默认勾选「跳过以后的短信验证」", isOn: $store.settings.preferSkipSecondaryAuth)
                    Text("二次短信时默认勾选跳过（提交加 $ 前缀，同 EZ4Connect）。是否生效取决于 aTrust 策略。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("高级") {
                    Toggle("Fake IP (TUN/aTrust)", isOn: $store.settings.fakeIP)
                    Toggle("TCP Tunnel", isOn: $store.settings.tcpTunnelMode)
                    Toggle("跳过域名资源", isOn: $store.settings.skipDomainResource)
                    Toggle("调试日志", isOn: $store.settings.debugMode)
                }

                Section("界面") {
                    Toggle("显示网络监测面板", isOn: $store.settings.showNetworkMonitor)
                    Toggle("紧凑布局", isOn: $store.settings.compactUI)
                    Toggle("登录时启动", isOn: $store.settings.launchAtLogin)
                        .onChange(of: store.settings.launchAtLogin) { _, v in
                            LaunchAtLogin.isEnabled = v
                        }
                    Toggle("启动时检查更新", isOn: $store.settings.checkUpdatesOnLaunch)
                }

                Section("更新") {
                    UpdateSettingsRow()
                }

                Section("协议引擎") {
                    LabeledContent("路径") {
                        Text(engine.coreBinaryPath ?? "未安装")
                            .font(.caption.monospaced())
                            .lineLimit(3)
                            .textSelection(.enabled)
                    }
                    HStack {
                        Button("重新检测") { engine.refreshCoreBinary() }
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

                Section("浙江大学预设") {
                    Button("恢复 ZJU 默认") {
                        store.applyZJUDefaults()
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("完成") {
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
                Text("当前版本")
                Spacer()
                Text(updater.currentVersion)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if let latest = updater.latestVersion {
                HStack {
                    Text("最新版本")
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
                    Button("打开发布页") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }
}
