import SwiftUI
import AppKit

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    private let projectURL = URL(string: "https://github.com/diyanqi/openZweb")!

    private let thanks: [(String, String, URL)] = [
        ("Mythologyli/zju-connect", "aTrust 协议引擎", URL(string: "https://github.com/Mythologyli/zju-connect")!),
        ("Mythologyli/ZJU-Connect-for-Windows", "Windows 客户端参考", URL(string: "https://github.com/Mythologyli/ZJU-Connect-for-Windows")!),
        ("chenx-dust/EZ4Connect", "aTrust 协议研究", URL(string: "https://github.com/chenx-dust/EZ4Connect")!),
        ("kaixuanwang2003/zju-welcome", "浙大导航 zjuers.com", URL(string: "https://github.com/kaixuanwang2003/zju-welcome/")!),
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                ZStack {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.78, green: 0.18, blue: 0.22),
                                    Color(red: 0.45, green: 0.08, blue: 0.14)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 88, height: 88)
                        .shadow(color: Color.red.opacity(0.28), radius: 12, y: 5)
                    Image(systemName: "shield.lefthalf.filled")
                        .font(.system(size: 40, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .padding(.top, 8)

                Text("OpenZweb")
                    .font(.system(.title, design: .rounded).weight(.bold))
                Text("浙江大学 · aTrust 原生客户端")
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent("版本", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0")
                    LabeledContent("协议引擎", value: "zju-connect")
                    LabeledContent("兼容", value: "深信服 aTrust / EZ4Connect")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                VStack(alignment: .leading, spacing: 10) {
                    Text("本项目")
                        .font(.headline)
                    creditRow(
                        title: "diyanqi/openZweb",
                        subtitle: "Swift 原生 macOS 客户端",
                        url: projectURL
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 10) {
                    Text("鸣谢开源项目")
                        .font(.headline)
                    ForEach(thanks, id: \.0) { item in
                        creditRow(title: item.0, subtitle: item.1, url: item.2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text("仅供校内学习科研网络访问。请遵守学校与相关服务条款。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)

                Button("关闭") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.borderedProminent)
                    .padding(.bottom, 8)
            }
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .frame(width: 440, height: 600)
    }

    private func creditRow(title: String, subtitle: String, url: URL) -> some View {
        Link(destination: url) {
            HStack(spacing: 12) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )
        }
        .buttonStyle(.plain)
    }
}
