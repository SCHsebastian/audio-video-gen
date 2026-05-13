import Foundation
import Domain
import Observation

@Observable
final class BundleLocalizer: Localizing, @unchecked Sendable {
    private(set) var current: Language = .system
    private var bundle: Bundle = .main
    private var version: Int = 0   // bumps on setLanguage; ensures @Observable invalidation propagates

    init(initialLanguage: Language) { setLanguage(initialLanguage) }

    var resolvedLocale: String {
        _ = version
        switch current {
        case .system:
            return Locale.preferredLanguages.first?.components(separatedBy: "-").first ?? "en"
        case .en: return "en"
        case .es: return "es"
        }
    }

    func setLanguage(_ lang: Language) {
        current = lang
        bundle = Self.bundleForLanguage(lang) ?? .main
        version &+= 1
    }

    func string(_ key: L10nKey) -> String {
        _ = version
        return NSLocalizedString(key.rawValue, bundle: bundle, comment: "")
    }

    private static func bundleForLanguage(_ lang: Language) -> Bundle? {
        let code: String
        switch lang {
        case .system:
            code = Locale.preferredLanguages.first?.components(separatedBy: "-").first ?? "en"
        case .en: code = "en"
        case .es: code = "es"
        }
        guard let path = Bundle.main.path(forResource: code, ofType: "lproj"),
              let b = Bundle(path: path) else { return nil }
        return b
    }
}
