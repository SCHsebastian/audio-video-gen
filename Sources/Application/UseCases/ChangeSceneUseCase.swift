import Domain

public struct ChangeSceneUseCase: Sendable {
    private let renderer: VisualizationRendering
    private let preferences: PreferencesStoring
    public init(renderer: VisualizationRendering, preferences: PreferencesStoring) {
        self.renderer = renderer; self.preferences = preferences
    }
    public func execute(_ kind: SceneKind) {
        renderer.setScene(kind)
        var p = preferences.load()
        p.lastScene = kind
        preferences.save(p)
    }
}
