import Foundation

/// Lightweight localization helpers. Keys live in `Localizable.xcstrings`.
enum L10n {
    static func t(_ key: String.LocalizationValue) -> String {
        String(localized: key, bundle: .main)
    }

    static func format(_ key: String.LocalizationValue, _ args: CVarArg...) -> String {
        let template = String(localized: key, bundle: .main)
        return withVaList(args) { ptr in
            NSString(format: template, locale: Locale.current, arguments: ptr) as String
        }
    }
}
