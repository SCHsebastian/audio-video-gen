import Domain

final class FakeLocalizing: Localizing, @unchecked Sendable {
    var current: Language = .system
    var resolvedLocale: String = "en"
    private(set) var stringCalls: [L10nKey] = []
    private(set) var setLanguageCalls: [Language] = []
    func string(_ key: L10nKey) -> String { stringCalls.append(key); return key.rawValue }
    func setLanguage(_ lang: Language) { setLanguageCalls.append(lang); current = lang }
}
