public struct UserPreferences: Equatable, Sendable {
    public var lastSource: AudioSource
    public var lastScene: SceneKind
    public var lastPaletteName: String
    public init(lastSource: AudioSource, lastScene: SceneKind, lastPaletteName: String) {
        self.lastSource = lastSource; self.lastScene = lastScene; self.lastPaletteName = lastPaletteName
    }
    public static let `default` = UserPreferences(lastSource: .systemWide, lastScene: .bars, lastPaletteName: "XP Neon")
}
