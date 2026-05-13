import Foundation
import Domain
import Application

@MainActor
final class CompositionRoot {
    let viewModel: VisualizerViewModel
    let renderer: MetalVisualizationRenderer
    let permission: TCCAudioCapturePermission

    init() throws {
        let capture = CoreAudioTapCapture()
        let discovery = RunningApplicationsDiscovery()
        let permission = TCCAudioCapturePermission()
        let prefs = UserDefaultsPreferences()
        let analyzer = VDSPSpectrumAnalyzer(bandCount: 64, sampleRate: SampleRate(hz: 48_000))
        let beats = EnergyBeatDetector()
        let renderer = try MetalVisualizationRenderer.make()

        let list = ListAudioSourcesUseCase(discovery: discovery)
        let select = SelectAudioSourceUseCase(preferences: prefs)
        let change = ChangeSceneUseCase(renderer: renderer, preferences: prefs)
        let start = StartVisualizationUseCase(capture: capture, analyzer: analyzer, beats: beats,
                                              renderer: renderer, permissions: permission)
        let stop = StopVisualizationUseCase(capture: capture)

        // Hydrate from preferences.
        let saved = prefs.load()
        renderer.setScene(saved.lastScene)

        self.viewModel = VisualizerViewModel(listSources: list, selectSource: select, changeScene: change,
                                             start: start, stop: stop, renderer: renderer)
        self.viewModel.currentScene = saved.lastScene
        self.viewModel.selectedSource = saved.lastSource
        self.renderer = renderer
        self.permission = permission
    }
}
