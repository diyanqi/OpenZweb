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
                    Label("在浏览器中打开", systemImage: "safari")
                }
                Button("关闭") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()

            // This sheet is a convenience browser only — it does NOT inject tickets into zju-connect.
            VStack(alignment: .leading, spacing: 6) {
                Label("说明：此处仅打开网页，登录成功后不会自动连 VPN。", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("要用统一身份认证连内网：在主界面认证方式选「统一身份认证 (CAS)」，再点「连接内网」，由协议引擎完成 CAS 流程。")
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
