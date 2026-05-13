import Foundation
import Domain
import Application
import Observation

@Observable
final class VisualizerViewModel {
    private(set) var state: VisualizationState = .idle
    var sources: [AudioSource] = [.systemWide]
    var selectedSource: AudioSource = .systemWide
    var currentScene: SceneKind = .bars

    private let listSources: ListAudioSourcesUseCase
    private let selectSourceUseCase: SelectAudioSourceUseCase
    private let changeScene: ChangeSceneUseCase
    private let start: StartVisualizationUseCase
    private let stop: StopVisualizationUseCase
    private var streamTask: Task<Void, Never>?

    init(listSources: ListAudioSourcesUseCase,
         selectSource: SelectAudioSourceUseCase,
         changeScene: ChangeSceneUseCase,
         start: StartVisualizationUseCase,
         stop: StopVisualizationUseCase) {
        self.listSources = listSources
        self.selectSourceUseCase = selectSource
        self.changeScene = changeScene
        self.start = start
        self.stop = stop
    }

    func onAppear() {
        Task { @MainActor in
            do { sources = try await listSources.execute() } catch { state = .error(.permissionDenied) }
            beginStream()
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
