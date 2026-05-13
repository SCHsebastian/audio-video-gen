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
    /// User-defined scene order. Drives the segmented toolbar order, the
    /// arrow-key cycle, and shuffle mode. Persisted as raw strings; unknown
    /// entries are dropped on load and missing kinds are appended in
    /// `SceneKind.allCases` order so adding a new scene to the enum keeps
    /// existing users on a sensible order.
    public var sceneOrder: [SceneKind]
    /// Shuffle mode: auto-advance to the next scene in `sceneOrder` every
    /// `shuffleIntervalSec` seconds.
    public var shuffleEnabled: Bool
    public var shuffleIntervalSec: Int
    public init(lastSource: AudioSource,
                lastScene: SceneKind,
                lastPaletteName: String,
                lastLanguage: Language,
                speed: Float = 1.0,
                audioGain: Float = 1.0,
                beatSensitivity: Float = 1.0,
                reduceMotion: Bool = false,
                showDiagnostics: Bool = false,
                maxFPS: Int = 120,
                sceneOrder: [SceneKind] = SceneKind.allCases,
                shuffleEnabled: Bool = false,
                shuffleIntervalSec: Int = 180) {
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
        self.sceneOrder = sceneOrder.isEmpty ? SceneKind.allCases : sceneOrder
        self.shuffleEnabled = shuffleEnabled
        self.shuffleIntervalSec = max(15, shuffleIntervalSec)
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
        maxFPS: 120,
        sceneOrder: SceneKind.allCases,
        shuffleEnabled: false,
        shuffleIntervalSec: 180)
}
