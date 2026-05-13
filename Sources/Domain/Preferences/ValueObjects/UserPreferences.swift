public struct UserPreferences: Equatable, Sendable {
    public var lastSource: AudioSource
    public var lastScene: SceneKind
    public var lastPaletteName: String
    public var lastLanguage: Language
    public var speed: Float
    public var audioGain: Float
    public var beatSensitivity: Float
    public var reduceMotion: Bool
    public var showDiagnostics: Bool
    public init(lastSource: AudioSource,
                lastScene: SceneKind,
                lastPaletteName: String,
                lastLanguage: Language,
                speed: Float = 1.0,
                audioGain: Float = 1.0,
                beatSensitivity: Float = 1.0,
                reduceMotion: Bool = false,
                showDiagnostics: Bool = false) {
        self.lastSource = lastSource
        self.lastScene = lastScene
        self.lastPaletteName = lastPaletteName
        self.lastLanguage = lastLanguage
        self.speed = speed
        self.audioGain = audioGain
        self.beatSensitivity = beatSensitivity
        self.reduceMotion = reduceMotion
        self.showDiagnostics = showDiagnostics
    }
    public static let `default` = UserPreferences(
        lastSource: .systemWide,
        lastScene: .bars,
        lastPaletteName: "XP Neon",
        lastLanguage: .system,
        speed: 1.0,
        audioGain: 1.0,
        beatSensitivity: 1.0,
        reduceMotion: false,
        showDiagnostics: false)
}
