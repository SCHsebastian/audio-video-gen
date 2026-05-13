public struct UserPreferences: Equatable, Sendable {
    public var lastSource: AudioSource
    public var lastScene: SceneKind
    public var lastPaletteName: String
    public var lastLanguage: Language
    public init(lastSource: AudioSource,
                lastScene: SceneKind,
                lastPaletteName: String,
                lastLanguage: Language) {
        self.lastSource = lastSource
        self.lastScene = lastScene
        self.lastPaletteName = lastPaletteName
        self.lastLanguage = lastLanguage
    }
    public static let `default` = UserPreferences(
        lastSource: .systemWide,
        lastScene: .bars,
        lastPaletteName: "XP Neon",
        lastLanguage: .system)
}
