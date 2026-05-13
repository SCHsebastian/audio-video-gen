import Foundation
import Domain
import Application
import Observation
import os.log

@Observable
final class VisualizerViewModel {
    private(set) var state: VisualizationState = .idle
    var currentScene: SceneKind = .bars
    var speed: Float = 1.0

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

    func setSpeed(_ s: Float) {
        let clamped = max(0.1, min(3.0, s))
        speed = clamped
        renderer.setSpeed(clamped)
        var prefs = preferences.load()
        prefs.speed = clamped
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
