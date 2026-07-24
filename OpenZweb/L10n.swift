import Foundation
import SwiftUI

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

/// Observable language gate so SwiftUI re-renders when the user switches language.
@MainActor
final class LanguageController: ObservableObject {
    static let shared = LanguageController()
    /// Bumps on every language change; use as `.id(language.revision)` on root views.
    @Published private(set) var revision: Int = 0
    @Published private(set) var language: AppLanguage = .system

    func apply(_ language: AppLanguage) {
        // Idempotent: avoid remounting the whole UI on no-op applies.
        let same = self.language == language
        L10n.apply(language: language)
        self.language = language
        if !same {
            revision &+= 1
        }
        objectWillChange.send()
    }
}

enum L10n {
    /// Effective locale for string lookup. `nil` semantics = system via `.current`.
    private(set) static var preferredLocale: Locale = .current

    static func apply(language: AppLanguage) {
        if let id = language.localeIdentifier {
            preferredLocale = Locale(identifier: id)
            UserDefaults.standard.set([id], forKey: "AppleLanguages")
        } else {
            preferredLocale = Locale.autoupdatingCurrent
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        }
        UserDefaults.standard.set(language.rawValue, forKey: "openzweb.appLanguage")
        // Ensure subsequent String(localized:) sees the preference.
        UserDefaults.standard.synchronize()
    }

    static func bootstrapFromDefaults() {
        let raw = UserDefaults.standard.string(forKey: "openzweb.appLanguage") ?? AppLanguage.system.rawValue
        let lang = AppLanguage(rawValue: raw) ?? .system
        apply(language: lang)
        // Keep LanguageController in sync (uses public apply; private(set) language is not writable here).
        Task { @MainActor in
            LanguageController.shared.apply(lang)
        }
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
