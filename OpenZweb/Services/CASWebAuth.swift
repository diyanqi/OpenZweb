import Foundation
import WebKit
import SwiftUI

/// Hosts Zhejiang University unified identity (CAS) login inside a native WebView.
/// After successful login, cookies can be inspected; for aTrust CAS, zju-connect
/// typically handles the CAS redirect itself. This view is primarily for password
/// recovery / account portal access and future ticket injection.
struct CASWebAuthView: NSViewRepresentable {
    let startURL: URL
    var onFinish: ((URL) -> Void)?
    var onCancel: (() -> Void)?

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: startURL))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish, onCancel: onCancel)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onFinish: ((URL) -> Void)?
        let onCancel: (() -> Void)?

        init(onFinish: ((URL) -> Void)?, onCancel: (() -> Void)?) {
            self.onFinish = onFinish
            self.onCancel = onCancel
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let url = navigationAction.request.url {
                // aTrust / CAS success redirects often land back on the VPN portal.
                let host = url.host?.lowercased() ?? ""
                if host.contains("vpn.zju.edu.cn") || host.contains("rvpn.zju.edu.cn") || host.contains("atrust") {
                    if url.absoluteString.contains("ticket=")
                        || url.absoluteString.contains("token")
                        || url.path.contains("portal") {
                        onFinish?(url)
                    }
                }
            }
            decisionHandler(.allow)
        }
    }
}

enum ZJUAuthURLs {
    /// ZJU unified identity authentication portal.
    static let casLogin = URL(string: "https://zjuam.zju.edu.cn/cas/login")!
    /// ZJU aTrust / campus VPN portal entry.
    static let rvpnPortal = URL(string: "https://vpn.zju.edu.cn")!
}
