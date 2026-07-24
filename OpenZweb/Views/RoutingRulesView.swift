import SwiftUI

/// Dedicated panel for proxy allow/deny lists (not buried in Settings).
struct RoutingRulesView: View {
    @EnvironmentObject private var store: SettingsStore
    @EnvironmentObject private var engine: ConnectEngine
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.t("routing.title"))
                        .font(.title2.weight(.semibold))
                    Text(L10n.t("routing.subtitle"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(L10n.t("common.done")) {
                    store.persist()
                    dismiss()
                }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)

            Divider()

            Form {
                Section {
                    Text(L10n.t("routing.allow_hint"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $store.settings.proxyAllowList)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 100, maxHeight: 160)
                    Text(L10n.t("routing.allow_example"))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } header: {
                    Text(L10n.t("routing.allow_header"))
                }

                Section {
                    Text(L10n.t("routing.deny_hint"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextEditor(text: $store.settings.proxyDenyList)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 100, maxHeight: 160)
                    Text(L10n.t("routing.deny_example"))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } header: {
                    Text(L10n.t("routing.deny_header"))
                }

                Section {
                    Button {
                        store.persist()
                        engine.hotApplyRoutingRules(store.settings)
                    } label: {
                        if engine.isApplyingRouting {
                            HStack {
                                ProgressView().controlSize(.small)
                                Text(L10n.t("routing.apply_now"))
                            }
                        } else {
                            Text(L10n.t("routing.apply_now"))
                        }
                    }
                    .disabled(engine.isApplyingRouting)
                    Text(L10n.t("routing.apply_now_hint"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(L10n.t("routing.note"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .padding(.horizontal, 8)
            .padding(.bottom, 12)
        }
        .frame(minWidth: 520, minHeight: 480)
        .onDisappear { store.persist() }
    }
}
