import Foundation
import Metal
import Domain
import Application

@MainActor
final class CompositionRoot {
    let viewModel: VisualizerViewModel
    let renderer: MetalVisualizationRenderer
    let permission: TCCAudioCapturePermission
    let localizer: BundleLocalizer
    let exportViewModel: ExportViewModel
    /// Fan-out adapter. The capture pipeline writes audio frames into this
    /// bus, which broadcasts them to every registered renderer (primary +
    /// any secondary renderer the user spawns for split view).
    let bus: RenderBus
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let library: MTLLibrary

    init() throws {
        let capture = CoreAudioTapCapture()
        let permission = TCCAudioCapturePermission()
        let prefs = UserDefaultsPreferences()
        let analyzer = VDSPSpectrumAnalyzer(bandCount: 64, sampleRate: SampleRate(hz: 48_000))
        let beats = EnergyBeatDetector()
        let renderer = try MetalVisualizationRenderer.make()
        let saved = prefs.load()
        let localizer = BundleLocalizer(initialLanguage: saved.lastLanguage)

        let bus = RenderBus()
        bus.register(renderer)

        let change = ChangeSceneUseCase(renderer: renderer, preferences: prefs)
        // Capture pipeline pushes into the bus so every renderer (including
        // any spawned for split view) sees the same audio frames.
        let start = StartVisualizationUseCase(capture: capture, analyzer: analyzer, beats: beats,
                                              renderer: bus, permissions: permission)
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
        self.bus = bus
        self.device = renderer.deviceForSecondary
        self.queue = renderer.queueForSecondary
        self.library = renderer.libraryForSecondary

        let decoder = AVAudioFileDecoder()
        let exportAnalyzer = VDSPSpectrumAnalyzer(bandCount: 64, sampleRate: SampleRate(hz: 48_000))
        let exportBeats = EnergyBeatDetector()
        let offlineRenderer = MetalVisualizationRenderer.makeOfflineRenderer(
            device: renderer.deviceForSecondary,
            queue: renderer.queueForSecondary,
            library: renderer.libraryForSecondary)
        let exportUseCase = ExportVisualizationUseCase(
            decoder: decoder, analyzer: exportAnalyzer, beats: exportBeats, renderer: offlineRenderer)
        self.exportViewModel = ExportViewModel(useCase: exportUseCase, localizer: localizer)
    }

    /// Build a secondary renderer (for split view), pre-loaded with the
    /// user's saved palette, and register it with the bus. Caller owns the
    /// returned renderer's lifetime and must call `releaseSecondary` when
    /// the split view goes away.
    func makeSecondaryRenderer(scene: SceneKind = .scope, palette: ColorPalette? = nil) -> MetalVisualizationRenderer {
        let r = MetalVisualizationRenderer.makeSecondary(device: device, queue: queue, library: library,
                                                         palette: palette ?? PaletteFactory.xpNeon)
        r.setScene(scene)
        bus.register(r)
        return r
    }

    func releaseSecondary(_ r: MetalVisualizationRenderer) {
        bus.unregister(r)
    }
}
