import SwiftUI

struct CASPortalSheet: View {
    @Binding var isPresented: Bool
    @State private var mode: PortalMode = .cas

    private enum PortalMode: String, CaseIterable, Identifiable {
        case cas = "统一身份认证"
        case rvpn = "VPN 门户"
        var id: String { rawValue }
    }

    private var url: URL {
        switch mode {
        case .cas: return ZJUAuthURLs.casLogin
        case .rvpn: return ZJUAuthURLs.rvpnPortal
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("页面", selection: $mode) {
                    ForEach(PortalMode.allCases) { item in
                        Text(item.rawValue).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 320)

                Spacer()

                Link(destination: url) {
                    Label(L10n.t("cas.open_browser"), systemImage: "safari")
                }
                Button(L10n.t("common.close")) { isPresented = false }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()

            // This sheet is a convenience browser only — it does NOT inject tickets into zju-connect.
            VStack(alignment: .leading, spacing: 6) {
                Label(L10n.t("cas.note"), systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(L10n.t("cas.howto"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)
            .padding(.bottom, 8)

            Divider()

            CASWebAuthView(startURL: url)
                .id(url.absoluteString)
        }
        .frame(minWidth: 720, minHeight: 560)
    }
}
