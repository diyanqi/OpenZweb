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
                    Text(L10n.t("captcha.title"))
                        .font(.system(.title2, design: .rounded).weight(.semibold))
                    Text(L10n.t("captcha.hint"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(L10n.t("common.cancel"), role: .cancel) { engine.disconnect() }
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
                        Button(L10n.t("captcha.refresh")) { engine.reloadCaptchaFromDisk() }
                        Button(L10n.t("common.submit")) { engine.submitCaptcha() }
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
