import Foundation
import Domain
import Application
import Observation
import os.log
import AppKit
import UniformTypeIdentifiers
import ImageIO

@Observable
final class VisualizerViewModel {
    private(set) var state: VisualizationState = .idle
    var currentScene: SceneKind = .bars
    var speed: Float = 1.0
    var audioGain: Float = 1.0
    var beatSensitivity: Float = 1.0
    var reduceMotion: Bool = false
    var showDiagnostics: Bool = false
    /// FPS cap fed to the MTKView. 0 = unlimited.
    var maxFPS: Int = 120
    /// Toast surfaced after a snapshot was saved (or failed). Auto-clears.
    var snapshotToast: String? = nil
    private var clearSnapshotToastTask: Task<Void, Never>? = nil

    let localizer: Localizing                  // public so views can read

    private let changeScene: ChangeSceneUseCase
    private let start: StartVisualizationUseCase
    private let stop: StopVisualizationUseCase
    private let renderer: MetalVisualizationRenderer
    private let preferences: PreferencesStoring
    private let changeLanguageUseCase: ChangeLanguageUseCase
    private var streamTask: Task<Void, Never>?
    private var silenceTask: Task<Void, Never>?
    private(set) var isSilent: Bool = false

    init(changeScene: ChangeSceneUseCase,
         start: StartVisualizationUseCase,
         stop: StopVisualizationUseCase,
         renderer: MetalVisualizationRenderer,
         preferences: PreferencesStoring,
         localizer: Localizing,
         changeLanguage: ChangeLanguageUseCase) {
        self.changeScene = changeScene
        self.start = start
        self.stop = stop
        self.renderer = renderer
        self.preferences = preferences
        self.localizer = localizer
        self.changeLanguageUseCase = changeLanguage
    }

    func changeLanguage(_ lang: Language) {
        changeLanguageUseCase.execute(lang)
    }

    func onAppear() {
        Log.vm.info("onAppear")
        Task { @MainActor in
            beginStream()
            startSilenceWatch()
        }
    }

    func selectScene(_ k: SceneKind) {
        Log.vm.info("selectScene: \(k.rawValue, privacy: .public)")
        currentScene = k
        changeScene.execute(k)
    }

    func randomizeLissajous() {
        renderer.randomizeLissajous()
    }

    /// Last "Randomized X" toast surfaced after a randomize action. Cleared
    /// after a short delay by the view layer.
    var lastRandomizedLabel: String? = nil
    private var clearLabelTask: Task<Void, Never>? = nil

    func randomizeCurrent() {
        if let label = renderer.randomizeCurrent() {
            lastRandomizedLabel = label
            clearLabelTask?.cancel()
            clearLabelTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(1200))
                if !Task.isCancelled { lastRandomizedLabel = nil }
            }
        }
    }

    /// Display name of the active palette, observed by the UI.
    var paletteName: String { currentPaletteName }
    private(set) var currentPaletteName: String = PaletteFactory.xpNeon.name

    func cyclePalette() {
        let all = PaletteFactory.all
        let idx = all.firstIndex(where: { $0.name == currentPaletteName }) ?? 0
        let next = all[(idx + 1) % all.count]
        currentPaletteName = next.name
        renderer.setPalette(next)
        var prefs = preferences.load()
        prefs.lastPaletteName = next.name
        preferences.save(prefs)
    }

    func applyInitialPalette(named name: String) {
        let all = PaletteFactory.all
        let palette = all.first(where: { $0.name == name }) ?? all[0]
        currentPaletteName = palette.name
        renderer.setPalette(palette)
    }

    /// Select a palette by name and persist the choice.
    func selectPalette(named name: String) {
        applyInitialPalette(named: name)
        persistPalette(named: name)
    }

    func persistPalette(named name: String) {
        var prefs = preferences.load()
        prefs.lastPaletteName = name
        preferences.save(prefs)
    }

    func setSpeed(_ s: Float) {
        let clamped = max(0.1, min(3.0, s))
        speed = clamped
        renderer.setSpeed(clamped)
        var prefs = preferences.load()
        prefs.speed = clamped
        preferences.save(prefs)
    }

    func setAudioGain(_ g: Float) {
        let clamped = max(0.25, min(4.0, g))
        audioGain = clamped
        renderer.setAudioGain(clamped)
        var prefs = preferences.load()
        prefs.audioGain = clamped
        preferences.save(prefs)
    }

    func setBeatSensitivity(_ s: Float) {
        let clamped = max(0.25, min(3.0, s))
        beatSensitivity = clamped
        renderer.setBeatSensitivity(clamped)
        var prefs = preferences.load()
        prefs.beatSensitivity = clamped
        preferences.save(prefs)
    }

    func setReduceMotion(_ on: Bool) {
        reduceMotion = on
        var prefs = preferences.load()
        prefs.reduceMotion = on
        preferences.save(prefs)
    }

    func setShowDiagnostics(_ on: Bool) {
        showDiagnostics = on
        var prefs = preferences.load()
        prefs.showDiagnostics = on
        preferences.save(prefs)
    }

    func toggleDiagnostics() { setShowDiagnostics(!showDiagnostics) }

    func setMaxFPS(_ fps: Int) {
        let clamped = max(0, min(240, fps))
        maxFPS = clamped
        var prefs = preferences.load()
        prefs.maxFPS = clamped
        preferences.save(prefs)
    }

    func applyInitial(prefs: UserPreferences) {
        audioGain = prefs.audioGain
        beatSensitivity = prefs.beatSensitivity
        reduceMotion = prefs.reduceMotion
        showDiagnostics = prefs.showDiagnostics
        maxFPS = prefs.maxFPS
        renderer.setAudioGain(prefs.audioGain)
        renderer.setBeatSensitivity(prefs.beatSensitivity)
    }

    func resetToDefaults() {
        let d = UserPreferences.default
        setSpeed(d.speed)
        setAudioGain(d.audioGain)
        setBeatSensitivity(d.beatSensitivity)
        setReduceMotion(d.reduceMotion)
        setShowDiagnostics(d.showDiagnostics)
        setMaxFPS(d.maxFPS)
        applyInitialPalette(named: d.lastPaletteName)
        var prefs = preferences.load()
        prefs.lastPaletteName = d.lastPaletteName
        preferences.save(prefs)
    }

    /// Save the next-rendered Metal frame as a PNG on the user's Desktop. The
    /// renderer is asked to capture the next drawable; once it returns we
    /// write the file and surface a toast.
    func saveSnapshot() {
        renderer.requestSnapshot { [weak self] cgImage in
            guard let self else { return }
            if let cgImage, let url = Self.snapshotURL(),
               let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) {
                CGImageDestinationAddImage(dest, cgImage, nil)
                if CGImageDestinationFinalize(dest) {
                    self.surfaceSnapshotToast("saved")
                    Log.vm.info("snapshot saved: \(url.path, privacy: .public)")
                    return
                }
            }
            self.surfaceSnapshotToast("failed")
            Log.vm.error("snapshot failed")
        }
    }

    private static func snapshotURL() -> URL? {
        let fm = FileManager.default
        guard let desktop = fm.urls(for: .desktopDirectory, in: .userDomainMask).first else { return nil }
        let ts = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        return desktop.appendingPathComponent("AudioVisualizer-\(ts).png")
    }

    private func surfaceSnapshotToast(_ kind: String) {
        snapshotToast = kind
        clearSnapshotToastTask?.cancel()
        clearSnapshotToastTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1500))
            if !Task.isCancelled { snapshotToast = nil }
        }
    }

    func randomPalette() {
        let all = PaletteFactory.all
        let pool = all.filter { $0.name != currentPaletteName }
        guard let pick = pool.randomElement() ?? all.first else { return }
        currentPaletteName = pick.name
        renderer.setPalette(pick)
        var prefs = preferences.load()
        prefs.lastPaletteName = pick.name
        preferences.save(prefs)
    }

    private func beginStream() {
        Log.vm.info("beginStream: systemWide")
        streamTask?.cancel()
        let useCase = start
        streamTask = Task { @MainActor in
            await stop.execute()
            for await s in await useCase.execute(source: .systemWide) {
                Log.vm.info("state: \(String(describing: s), privacy: .public)")
                self.state = s
            }
        }
    }

    private func startSilenceWatch() {
        silenceTask?.cancel()
        silenceTask = Task { @MainActor [weak self] in
            var silentSinceMs: Int = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self else { return }
                let rms = self.renderer.peekRMS()
                if rms < 0.005 { silentSinceMs += 250 } else { silentSinceMs = 0 }
                self.isSilent = silentSinceMs >= 2000
            }
        }
    }
}
