import Foundation
import Domain
import Application

@MainActor
final class CompositionRoot {
    let viewModel: VisualizerViewModel
    let renderer: MetalVisualizationRenderer
    let permission: TCCAudioCapturePermission
    let localizer: BundleLocalizer    // NEW — exposed for the view layer

    init() throws {
        let capture = CoreAudioTapCapture()
        let permission = TCCAudioCapturePermission()
        let prefs = UserDefaultsPreferences()
        let analyzer = VDSPSpectrumAnalyzer(bandCount: 64, sampleRate: SampleRate(hz: 48_000))
        let beats = EnergyBeatDetector()
        let renderer = try MetalVisualizationRenderer.make()
        let saved = prefs.load()
        let localizer = BundleLocalizer(initialLanguage: saved.lastLanguage)

        let change = ChangeSceneUseCase(renderer: renderer, preferences: prefs)
        let start = StartVisualizationUseCase(capture: capture, analyzer: analyzer, beats: beats,
                                              renderer: renderer, permissions: permission)
        let stop = StopVisualizationUseCase(capture: capture)
        let changeLanguage = ChangeLanguageUseCase(localizer: localizer, preferences: prefs)

        renderer.setScene(saved.lastScene)
        renderer.setSpeed(saved.speed)
        self.viewModel = VisualizerViewModel(
            changeScene: change,
            start: start, stop: stop,
            renderer: renderer,
            preferences: prefs,
            localizer: localizer, changeLanguage: changeLanguage)
        self.viewModel.currentScene = saved.lastScene
        self.viewModel.speed = saved.speed
        self.viewModel.applyInitialPalette(named: saved.lastPaletteName)
        self.viewModel.applyInitial(prefs: saved)
        self.renderer = renderer
        self.permission = permission
        self.localizer = localizer
    }
}
