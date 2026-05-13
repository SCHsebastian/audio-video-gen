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
    /// Target frames per second for the Metal view. `0` means "unlimited"
    /// (i.e. the display's preferred refresh rate, typically 120 on ProMotion).
    public var maxFPS: Int
    public init(lastSource: AudioSource,
                lastScene: SceneKind,
                lastPaletteName: String,
                lastLanguage: Language,
                speed: Float = 1.0,
                audioGain: Float = 1.0,
                beatSensitivity: Float = 1.0,
                reduceMotion: Bool = false,
                showDiagnostics: Bool = false,
                maxFPS: Int = 120) {
        self.lastSource = lastSource
        self.lastScene = lastScene
        self.lastPaletteName = lastPaletteName
        self.lastLanguage = lastLanguage
        self.speed = speed
        self.audioGain = audioGain
        self.beatSensitivity = beatSensitivity
        self.reduceMotion = reduceMotion
        self.showDiagnostics = showDiagnostics
        self.maxFPS = maxFPS
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
        showDiagnostics: false,
        maxFPS: 120)
}
