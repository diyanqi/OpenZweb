import Foundation

enum AppLanguage: String, CaseIterable, Identifiable, Codable {
    case system
    case zhHans = "zh-Hans"
    case zhHant = "zh-Hant"
    case en

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return L10n.t("lang.system")
        case .zhHans: return L10n.t("lang.zh_hans")
        case .zhHant: return L10n.t("lang.zh_hant")
        case .en: return L10n.t("lang.en")
        }
    }

    /// Resolved BCP-47 code, or nil to follow system.
    var localeIdentifier: String? {
        switch self {
        case .system: return nil
        case .zhHans: return "zh-Hans"
        case .zhHant: return "zh-Hant"
        case .en: return "en"
        }
    }
}

enum L10n {
    /// Effective locale for string lookup. `nil` = system.
    static var preferredLocale: Locale = .current {
        didSet { /* views refresh via SettingsStore objectWillChange */ }
    }

    static func apply(language: AppLanguage) {
        if let id = language.localeIdentifier {
            preferredLocale = Locale(identifier: id)
            UserDefaults.standard.set([id], forKey: "AppleLanguages")
        } else {
            preferredLocale = .current
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        }
        UserDefaults.standard.set(language.rawValue, forKey: "openzweb.appLanguage")
    }

    static func bootstrapFromDefaults() {
        let raw = UserDefaults.standard.string(forKey: "openzweb.appLanguage") ?? AppLanguage.system.rawValue
        let lang = AppLanguage(rawValue: raw) ?? .system
        apply(language: lang)
    }

    static func t(_ key: String.LocalizationValue) -> String {
        String(localized: key, locale: preferredLocale)
    }

    static func format(_ key: String.LocalizationValue, _ args: CVarArg...) -> String {
        let template = String(localized: key, locale: preferredLocale)
        return withVaList(args) { ptr in
            NSString(format: template, locale: preferredLocale, arguments: ptr) as String
        }
    }
}
