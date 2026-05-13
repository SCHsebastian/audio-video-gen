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
        let discovery = RunningApplicationsDiscovery()
        let permission = TCCAudioCapturePermission()
        let prefs = UserDefaultsPreferences()
        let analyzer = VDSPSpectrumAnalyzer(bandCount: 64, sampleRate: SampleRate(hz: 48_000))
        let beats = EnergyBeatDetector()
        let renderer = try MetalVisualizationRenderer.make()
        let saved = prefs.load()
        let localizer = BundleLocalizer(initialLanguage: saved.lastLanguage)

        let list = ListAudioSourcesUseCase(discovery: discovery)
        let select = SelectAudioSourceUseCase(preferences: prefs)
        let change = ChangeSceneUseCase(renderer: renderer, preferences: prefs)
        let start = StartVisualizationUseCase(capture: capture, analyzer: analyzer, beats: beats,
                                              renderer: renderer, permissions: permission)
        let stop = StopVisualizationUseCase(capture: capture)

        renderer.setScene(saved.lastScene)
        self.viewModel = VisualizerViewModel(
            listSources: list, selectSource: select, changeScene: change,
            start: start, stop: stop,
            discovery: discovery, renderer: renderer, localizer: localizer)
        self.viewModel.currentScene = saved.lastScene
        self.viewModel.selectedSource = saved.lastSource
        self.renderer = renderer
        self.permission = permission
        self.localizer = localizer
    }
}
