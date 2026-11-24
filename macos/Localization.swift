import Foundation

enum AppLanguage: String, CaseIterable, Codable {
    case system, english = "en", simplifiedChinese = "zh-Hans"

    func resolved(preferences: [String] = Locale.preferredLanguages) -> Self {
        guard self == .system else { return self }
        let supported = [Self.english.rawValue, Self.simplifiedChinese.rawValue]
        let preferred = Bundle.preferredLocalizations(from: supported, forPreferences: preferences).first
        return preferred.flatMap(Self.init(rawValue:)) ?? .english
    }

    func title(in strings: AppStrings) -> String {
        switch self {
        case .system: return strings("Follow System")
        case .english: return "English"
        case .simplifiedChinese: return "简体中文"
        }
    }
}

private final class LocalizationBundleMarker {}

struct AppStrings {
    private static let bundles: [AppLanguage: Bundle] = {
        // The Finder Sync extension runs in a different process from the settings app.
        let owner = Bundle(for: LocalizationBundleMarker.self)
        return Dictionary(uniqueKeysWithValues: [AppLanguage.english, .simplifiedChinese].compactMap { language in
            owner.url(forResource: language.rawValue, withExtension: "lproj")
                .flatMap(Bundle.init(url:)).map { (language, $0) }
        })
    }()

    let language: AppLanguage
    var locale: Locale { Locale(identifier: language.rawValue) }

    init(language: AppLanguage = .system, preferences: [String] = Locale.preferredLanguages) {
        self.language = language.resolved(preferences: preferences)
    }

    static var current: Self {
        Self(language: (try? Settings.load())?.language ?? .system)
    }

    func callAsFunction(_ key: String, _ arguments: CVarArg...) -> String {
        let value = Self.bundles[language]?.localizedString(forKey: key, value: key, table: nil) ?? key
        guard !arguments.isEmpty else { return value }
        return String(format: value, locale: locale, arguments: arguments)
    }
}
