import Domain

final class FakePreferencesStoring: PreferencesStoring, @unchecked Sendable {
    var stored: UserPreferences = .default
    func load() -> UserPreferences { stored }
    func save(_ prefs: UserPreferences) { stored = prefs }
}
