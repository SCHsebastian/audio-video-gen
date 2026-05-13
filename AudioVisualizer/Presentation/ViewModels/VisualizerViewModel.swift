import Foundation
import Domain
import Application
import Observation

@Observable
final class VisualizerViewModel {
    private(set) var state: VisualizationState = .idle
    private(set) var isSilent: Bool = false
    var sources: [AudioSource] = [.systemWide]
    var selectedSource: AudioSource = .systemWide
    var currentScene: SceneKind = .bars

    private let listSources: ListAudioSourcesUseCase
    private let selectSourceUseCase: SelectAudioSourceUseCase
    private let changeScene: ChangeSceneUseCase
    private let start: StartVisualizationUseCase
    private let stop: StopVisualizationUseCase
    private let renderer: MetalVisualizationRenderer
    private var streamTask: Task<Void, Never>?
    private var silenceTask: Task<Void, Never>?

    init(listSources: ListAudioSourcesUseCase,
         selectSource: SelectAudioSourceUseCase,
         changeScene: ChangeSceneUseCase,
         start: StartVisualizationUseCase,
         stop: StopVisualizationUseCase,
         renderer: MetalVisualizationRenderer) {
        self.listSources = listSources
        self.selectSourceUseCase = selectSource
        self.changeScene = changeScene
        self.start = start
        self.stop = stop
        self.renderer = renderer
    }

    func onAppear() {
        Task { @MainActor in
            do { sources = try await listSources.execute() } catch { state = .error(.permissionDenied) }
            beginStream()
            startSilenceWatch()
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

    func selectScene(_ k: SceneKind) {
        currentScene = k
        changeScene.execute(k)
    }

    func selectSource(_ s: AudioSource) {
        selectedSource = s
        selectSourceUseCase.execute(s)
        beginStream()
    }

    private func beginStream() {
        streamTask?.cancel()
        let useCase = start
        let chosen = selectedSource
        streamTask = Task { @MainActor in
            await stop.execute()
            for await s in await useCase.execute(source: chosen) {
                self.state = s
            }
        }
    }
}
