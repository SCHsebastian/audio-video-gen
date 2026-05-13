public struct UserPreferences: Equatable, Sendable {
    public var lastSource: AudioSource
    public var lastScene: SceneKind
    public var lastPaletteName: String
    public var lastLanguage: Language
    public var speed: Float
    public init(lastSource: AudioSource,
                lastScene: SceneKind,
                lastPaletteName: String,
                lastLanguage: Language,
                speed: Float = 1.0) {
        self.lastSource = lastSource
        self.lastScene = lastScene
        self.lastPaletteName = lastPaletteName
        self.lastLanguage = lastLanguage
        self.speed = speed
    }
    public static let `default` = UserPreferences(
        lastSource: .systemWide,
        lastScene: .bars,
        lastPaletteName: "XP Neon",
        lastLanguage: .system,
        speed: 1.0)
}
