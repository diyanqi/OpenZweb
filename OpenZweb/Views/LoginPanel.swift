import SwiftUI

struct LoginPanel: View {
    @EnvironmentObject private var engine: ConnectEngine
    @EnvironmentObject private var store: SettingsStore
    @Binding var password: String
    @FocusState private var focusedField: Field?

    private enum Field { case username, password }

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                header
                formCard
                actionRow
                if let error = engine.lastError, case .failed = engine.phase {
                    errorBanner(error)
                }
                if engine.coreBinaryPath == nil {
                    coreMissingBanner
                } else if let note = engine.coreBinaryNote {
                    noteBanner(note, icon: "exclamationmark.triangle", tint: .orange)
                }
                if !canConnect, engine.phase == .idle || isFailedPhase {
                    if let reason = connectBlockReason {
                        noteBanner(reason, icon: "info.circle", tint: .secondary)
                    }
                }
            }
            .padding(36)
            .frame(maxWidth: store.settings.compactUI ? 460 : 520)
            .frame(maxWidth: .infinity)
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            Image(systemName: "building.columns.fill")
                .font(.system(size: 42, weight: .medium))
                .foregroundStyle(
                    LinearGradient(
                        colors: [
                            Color(red: 0.85, green: 0.25, blue: 0.28),
                            Color(red: 0.55, green: 0.1, blue: 0.18)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .symbolRenderingMode(.hierarchical)
            Text("浙江大学校内网")
                .font(.system(.largeTitle, design: .rounded).weight(.bold))
            Text("深信服 aTrust · 优雅接入校园 VPN")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 8)
    }

    private var formCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            fieldLabel("学号 / 用户名")
            TextField("例如 322010XXXX", text: $store.settings.username)
                .textFieldStyle(.roundedBorder)
                .focused($focusedField, equals: .username)
                .disabled(engine.phase.isBusy)

            fieldLabel("密码")
            SecureField("统一身份认证 / 校园网密码", text: $password)
                .textFieldStyle(.roundedBorder)
                .focused($focusedField, equals: .password)
                .disabled(engine.phase.isBusy)
                .onSubmit(connect)

            Picker("认证方式", selection: $store.settings.authMethod) {
                ForEach(AuthMethod.allCases) { method in
                    Text(method.displayName).tag(method)
                }
            }
            .pickerStyle(.segmented)
            .disabled(engine.phase.isBusy)

            Picker("连接模式", selection: $store.settings.connectionMode) {
                ForEach(ConnectionMode.allCases) { mode in
                    Text(mode == .proxy ? "代理" : "TUN").tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .disabled(engine.phase.isBusy)

            if store.settings.tunMode {
                Label("TUN 需要管理员密码，可实现系统级内网访问", systemImage: "lock.shield")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Toggle("记住密码（钥匙串）", isOn: $store.settings.rememberPassword)
                .disabled(engine.phase.isBusy)

            Toggle("连接后自动设置系统代理", isOn: $store.settings.manageSystemProxy)
                .disabled(engine.phase.isBusy)
            if !store.settings.manageSystemProxy {
                Text("与 Clash 共存：不改系统代理；把校内域名规则指到本机 SOCKS。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Toggle("连接后向局域网共享代理", isOn: $store.settings.shareOnLAN)
                .disabled(engine.phase.isBusy)
            if store.settings.shareOnLAN {
                Text("将监听 0.0.0.0，其他设备可扫码使用本机代理。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("登录域")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(store.settings.loginDomain)
                    .font(.body.monospaced())
            }
            .font(.callout)
        }
        .padding(22)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.05), radius: 20, y: 8)
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private var actionRow: some View {
        HStack(spacing: 12) {
            if engine.phase.isBusy {
                Button("取消") { engine.disconnect() }
                    .keyboardShortcut(.cancelAction)
            }
            Button(action: connect) {
                HStack(spacing: 8) {
                    if engine.phase.isBusy {
                        ProgressView().controlSize(.small)
                    }
                    Text(engine.phase.isBusy ? engine.phase.title : "连接内网")
                        .frame(minWidth: 128)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!canConnect || engine.phase.isBusy)
            .keyboardShortcut(.defaultAction)
        }
    }

    private var canConnect: Bool {
        !store.settings.username.isEmpty
            && !password.isEmpty
            && engine.coreBinaryPath != nil
            && !engine.phase.isBusy
    }

    private var isFailedPhase: Bool {
        if case .failed = engine.phase { return true }
        return false
    }

    private var connectBlockReason: String? {
        if engine.phase.isBusy { return nil }
        if store.settings.username.isEmpty { return "请先输入学号 / 用户名" }
        if password.isEmpty { return "请先输入密码" }
        if engine.coreBinaryPath == nil { return "协议引擎未就绪，请先下载 zju-connect" }
        return nil
    }

    private var coreMissingBanner: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("尚未安装 aTrust 协议引擎", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            Text("OpenZweb 使用开源 zju-connect 实现 aTrust / EasyConnect。")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button {
                Task { await engine.downloadCore() }
            } label: {
                if engine.isDownloadingCore { ProgressView().controlSize(.small) }
                else { Text("下载协议引擎") }
            }
            .buttonStyle(.borderedProminent)
            .disabled(engine.isDownloadingCore)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func noteBanner(_ message: String, icon: String, tint: Color) -> some View {
        Label(message, systemImage: icon)
            .font(.callout)
            .foregroundStyle(tint)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func errorBanner(_ message: String) -> some View {
        Label(message, systemImage: "xmark.octagon.fill")
            .foregroundStyle(.red)
            .font(.callout)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func connect() {
        store.persist()
        engine.connect(settings: store.settings, password: password)
    }
}
