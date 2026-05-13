import Foundation
import Domain
import Application
import Observation

@Observable
final class VisualizerViewModel {
    private(set) var state: VisualizationState = .idle
    var sources: [AudioSource] = [.systemWide]
    var processInfos: [AudioProcessInfo] = []
    var selectedSource: AudioSource = .systemWide
    var currentScene: SceneKind = .bars

    let localizer: Localizing                  // public so views can read

    private let listSources: ListAudioSourcesUseCase
    private let selectSourceUseCase: SelectAudioSourceUseCase
    private let changeScene: ChangeSceneUseCase
    private let start: StartVisualizationUseCase
    private let stop: StopVisualizationUseCase
    private let discovery: ProcessDiscovering
    private let renderer: MetalVisualizationRenderer
    private let changeLanguageUseCase: ChangeLanguageUseCase
    private var streamTask: Task<Void, Never>?
    private var silenceTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private(set) var isSilent: Bool = false

    init(listSources: ListAudioSourcesUseCase,
         selectSource: SelectAudioSourceUseCase,
         changeScene: ChangeSceneUseCase,
         start: StartVisualizationUseCase,
         stop: StopVisualizationUseCase,
         discovery: ProcessDiscovering,
         renderer: MetalVisualizationRenderer,
         localizer: Localizing,
         changeLanguage: ChangeLanguageUseCase) {
        self.listSources = listSources
        self.selectSourceUseCase = selectSource
        self.changeScene = changeScene
        self.start = start
        self.stop = stop
        self.discovery = discovery
        self.renderer = renderer
        self.localizer = localizer
        self.changeLanguageUseCase = changeLanguage
    }

    func changeLanguage(_ lang: Language) {
        changeLanguageUseCase.execute(lang)
    }

    func onAppear() {
        Task { @MainActor in
            await refreshSources()
            beginStream()
            startSilenceWatch()
            startRefreshLoop()
        }
    }

    func refreshSources() async {
        do {
            sources = try await listSources.execute()
            processInfos = (try? await discovery.listAudioProcesses()) ?? []
        } catch {
            state = .error(.permissionDenied)
        }
    }

    func displayName(for source: AudioSource) -> String {
        switch source {
        case .systemWide:
            return localizer.string(.sourceSystemWide)
        case .process(_, let bundleID):
            return processInfos.first(where: { $0.bundleID == bundleID })?.displayName ?? bundleID
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

    private func startRefreshLoop() {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard let self else { return }
                await self.refreshSources()
            }
        }
    }
}
