public protocol PreferencesStoring: Sendable {
    func load() -> UserPreferences
    func save(_ prefs: UserPreferences)
}
