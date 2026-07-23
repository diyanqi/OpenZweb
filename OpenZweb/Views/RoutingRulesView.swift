import SwiftUI

/// Dedicated panel for proxy allow/deny lists (not buried in Settings).
struct RoutingRulesView: View {
    @EnvironmentObject private var store: SettingsStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("分流规则")
                        .font(.title2.weight(.semibold))
                    Text("白名单写入引擎；黑名单写入系统代理绕过列表")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)

            Divider()

            Form {
                Section {
                    Text("强制走校园 VPN 的域名（zju-connect `custom_proxy_domain`）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $store.settings.proxyAllowList)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 100, maxHeight: 160)
                    Text("示例：science.org, nature.com 或每行一个")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } header: {
                    Text("白名单（强制代理）")
                }

                Section {
                    Text("在系统代理中直连（不经本机 VPN 代理）的域名")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $store.settings.proxyDenyList)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 100, maxHeight: 160)
                    Text("示例：localhost, music.163.com — 仅在开启「自动设置系统代理」时生效")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } header: {
                    Text("黑名单（直连绕过）")
                }

                Section {
                    Text("修改后下次连接生效。已连接时请断开后重新连接以应用白名单。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .padding(.horizontal, 8)
            .padding(.bottom, 12)
        }
        .frame(minWidth: 520, minHeight: 480)
    }
}
