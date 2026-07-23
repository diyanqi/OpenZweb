import SwiftUI
import WebKit

struct CaptchaPanel: View {
    @EnvironmentObject private var engine: ConnectEngine
    @EnvironmentObject private var store: SettingsStore
    @Binding var password: String

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("人机验证")
                        .font(.system(.title2, design: .rounded).weight(.semibold))
                    Text("在下方点选验证码字符。完成后会自动继续登录。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("取消", role: .cancel) { engine.disconnect() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(18)

            Divider().opacity(0.5)

            if let url = engine.captchaServerURL {
                CaptchaWebView(url: url)
                    .clipShape(RoundedRectangle(cornerRadius: 0))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let image = engine.captchaImage {
                VStack(spacing: 20) {
                    Spacer()
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.none)
                        .scaledToFit()
                        .frame(height: 88)
                        .padding(14)
                        .background(.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
                    HStack(spacing: 10) {
                        TextField("验证码", text: $engine.captchaCode)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 160)
                            .onSubmit { engine.submitCaptcha() }
                        Button("刷新") { engine.reloadCaptchaFromDisk() }
                        Button("提交") { engine.submitCaptcha() }
                            .buttonStyle(.borderedProminent)
                            .disabled(engine.captchaCode.isEmpty)
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView("等待验证码…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct CaptchaWebView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        if webView.url != url {
            webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30))
        }
    }
}
