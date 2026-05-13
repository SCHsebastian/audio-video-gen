import Domain

public struct ChangeLanguageUseCase: Sendable {
    private let localizer: Localizing
    private let preferences: PreferencesStoring
    public init(localizer: Localizing, preferences: PreferencesStoring) {
        self.localizer = localizer
        self.preferences = preferences
    }
    public func execute(_ lang: Language) {
        localizer.setLanguage(lang)
        var p = preferences.load()
        p.lastLanguage = lang
        preferences.save(p)
    }
}
