import XCTest
@testable import Application
@testable import Domain

final class FakeRenderer: VisualizationRendering, @unchecked Sendable {
    var scene: SceneKind?
    var palette: ColorPalette?
    var lastSpectrum: SpectrumFrame?
    func setScene(_ kind: SceneKind) { scene = kind }
    func setPalette(_ palette: ColorPalette) { self.palette = palette }
    func consume(spectrum: SpectrumFrame, waveform: WaveformBuffer, beat: BeatEvent?) { lastSpectrum = spectrum }
}

final class ChangeSceneUseCaseTests: XCTestCase {
    func test_sets_scene_on_renderer_and_persists() {
        let r = FakeRenderer()
        let p = FakePreferencesStoring()
        let sut = ChangeSceneUseCase(renderer: r, preferences: p)
        sut.execute(.alchemy)
        XCTAssertEqual(r.scene, .alchemy)
        XCTAssertEqual(p.stored.lastScene, .alchemy)
    }
}
