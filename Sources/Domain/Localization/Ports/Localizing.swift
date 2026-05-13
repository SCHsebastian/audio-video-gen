public protocol Localizing: AnyObject, Sendable {
    func string(_ key: L10nKey) -> String
    func setLanguage(_ lang: Language)
    var current: Language { get }
    var resolvedLocale: String { get }
}
