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
            BrandMarkTapView(size: 64, cornerRadius: 16)
            Text(L10n.t("login.title"))
                .font(.system(.largeTitle, design: .rounded).weight(.bold))
            Text(L10n.t("login.subtitle"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 8)
    }

    private var formCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            fieldLabel(L10n.t("login.username"))
            TextField(L10n.t("login.username_ph"), text: $store.settings.username)
                .textFieldStyle(.roundedBorder)
                .focused($focusedField, equals: .username)
                .disabled(engine.phase.isBusy)

            fieldLabel(L10n.t("login.password"))
            SecureField(L10n.t("login.password_ph"), text: $password)
                .textFieldStyle(.roundedBorder)
                .focused($focusedField, equals: .password)
                .disabled(engine.phase.isBusy)
                .onSubmit(connect)

            Picker(L10n.t("login.auth_method"), selection: $store.settings.authMethod) {
                ForEach(AuthMethod.allCases) { method in
                    Text(method.displayName).tag(method)
                }
            }
            .pickerStyle(.segmented)
            .disabled(engine.phase.isBusy)

            Picker(L10n.t("login.conn_mode"), selection: $store.settings.connectionMode) {
                ForEach(ConnectionMode.allCases) { mode in
                    Text(mode == .proxy ? L10n.t("mode.proxy_short") : L10n.t("mode.tun")).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .disabled(engine.phase.isBusy)

            if store.settings.tunMode {
                Label(L10n.t("login.tun_hint"), systemImage: "lock.shield")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Toggle(L10n.t("login.remember"), isOn: $store.settings.rememberPassword)
                .disabled(engine.phase.isBusy)

            Toggle(L10n.t("login.manage_proxy"), isOn: $store.settings.manageSystemProxy)
                .disabled(engine.phase.isBusy)
            if !store.settings.manageSystemProxy {
                Text(L10n.t("login.manage_proxy_hint"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Toggle(L10n.t("login.share_lan"), isOn: $store.settings.shareOnLAN)
                .disabled(engine.phase.isBusy)
            if store.settings.shareOnLAN {
                Text(L10n.t("login.share_lan_hint"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text(L10n.t("login.domain"))
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
                Button(L10n.t("common.cancel")) { engine.disconnect() }
                    .keyboardShortcut(.cancelAction)
            }
            Button(action: connect) {
                HStack(spacing: 8) {
                    if engine.phase.isBusy {
                        ProgressView().controlSize(.small)
                    }
                    Text(engine.phase.isBusy ? engine.phase.title : L10n.t("login.connect"))
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
            Label(L10n.t("login.core_missing_title"), systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            Text(L10n.t("login.core_desc"))
                .font(.callout)
                .foregroundStyle(.secondary)
            Button {
                Task { await engine.downloadCore() }
            } label: {
                if engine.isDownloadingCore { ProgressView().controlSize(.small) }
                else { Text(L10n.t("login.download_engine")) }
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
