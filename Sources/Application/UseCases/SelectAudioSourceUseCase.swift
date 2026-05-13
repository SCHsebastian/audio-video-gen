import Domain

public struct SelectAudioSourceUseCase: Sendable {
    private let preferences: PreferencesStoring
    public init(preferences: PreferencesStoring) { self.preferences = preferences }
    public func execute(_ source: AudioSource) {
        var p = preferences.load()
        p.lastSource = source
        preferences.save(p)
    }
}
