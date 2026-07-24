import Foundation
import Combine

@MainActor
final class SettingsStore: ObservableObject {
    @Published var settings: AppSettings {
        didSet {
            // Keep L10n in sync when language is mutated via Binding.
            if oldValue.appLanguage != settings.appLanguage {
                LanguageController.shared.apply(settings.appLanguage)
            }
            settings.save()
        }
    }

    init() {
        settings = AppSettings.load()
        LanguageController.shared.apply(settings.appLanguage)
    }

    func persist() {
        settings.save()
    }

    func applyZJUDefaults() {
        settings.serverAddress = "vpn.zju.edu.cn"
        settings.serverPort = 443
        settings.protocolKind = .atrust
        settings.authMethod = .password
        settings.loginDomain = "Radius"
        settings.zjuDnsServer = "10.10.0.21"
        settings.secondaryDnsServer = "114.114.114.114"
        settings.disableServerConfig = true
        settings.socksBind = "127.0.0.1:1080"
        settings.httpBind = "127.0.0.1:1081"
        settings.connectionMode = .proxy
        settings.manageSystemProxy = true
        settings.manageSystemDNS = true
        settings.shareOnLAN = false
        settings.showNetworkMonitor = true
        settings.addRoute = true
        settings.dnsHijack = true
        settings.dnsAutoSetup = true
    }
}
