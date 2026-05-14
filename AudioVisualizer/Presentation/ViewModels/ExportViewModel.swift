import Foundation
import Observation
import Domain
import Application

/// Presentation view-model for the offline export feature. Owns:
///   1. The sheet form state (audio URL, output URL, scene, palette, resolution, fps).
///   2. The most recent `ExportState` yielded by the use case.
///   3. The background `Task` so Cancel can tear it down deterministically.
///
/// The Application module's `ExportState` does not have an `.idle` case — it
/// goes straight from no-state to `.preparing` on the first yield. We model
/// idle here as `state == nil` to avoid touching Application; the chip view
/// renders `EmptyView()` for the nil case.
@MainActor
@Observable
final class ExportViewModel {
    var state: ExportState? = nil
    var lastCompletedURL: URL? = nil

    var audioURL: URL? = nil
    var outputURL: URL? = nil
    var scene: SceneKind = .bars
    var paletteName: String = PaletteFactory.xpNeon.name
    var resolution: RenderOptions.Resolution = .hd1080
    var frameRate: RenderOptions.FrameRate = .fps60
    var isSheetPresented: Bool = false

    /// AI Game starting-progress catalog. Refreshed on sheet appear.
    private(set) var availableProgresses: [AIGameProgress] = []
    /// nil ⇒ "Random / fresh" (the offline renderer seeds from a cold start).
    var selectedProgressID: UUID? = nil

    let localizer: BundleLocalizer
    private let useCase: ExportVisualizationUseCase
    private let listProgresses: ListAIGameProgressUseCase
    private let loadProgress: LoadAIGameProgressUseCase
    private var task: Task<Void, Never>? = nil
    private var autoDismissTask: Task<Void, Never>? = nil

    init(useCase: ExportVisualizationUseCase,
         localizer: BundleLocalizer,
         listProgresses: ListAIGameProgressUseCase,
         loadProgress: LoadAIGameProgressUseCase) {
        self.useCase = useCase
        self.localizer = localizer
        self.listProgresses = listProgresses
        self.loadProgress = loadProgress
    }

    /// Refresh `availableProgresses` from disk. Failures collapse to an empty
    /// list — the picker still shows "Random / fresh", which is a valid choice.
    func reloadAvailableProgresses() {
        availableProgresses = (try? listProgresses.execute()) ?? []
        // If the previously-selected ID no longer exists (e.g. user deleted
        // the snapshot from another window), drop the selection so the picker
        // doesn't render an unselected tag.
        if let id = selectedProgressID,
           !availableProgresses.contains(where: { $0.id == id }) {
            selectedProgressID = nil
        }
    }

    func presentSheet() {
        isSheetPresented = true
    }

    /// Kick off the export. Caller (UI) must ensure `audioURL` and `outputURL`
    /// are non-nil — the Start button is disabled until both are picked.
    func start() {
        guard let audio = audioURL, let output = outputURL else { return }
        let palette = PaletteFactory.all.first(where: { $0.name == paletteName })
            ?? PaletteFactory.xpNeon
        let options = RenderOptions.make(resolution, frameRate)
        let selectedScene = scene
        let selectedOutput = output

        // Resolve the AI Game seed lazily — only when the user picked the
        // AI Game scene AND a specific snapshot. A failed load (snapshot
        // disappeared, topology mismatch) silently falls back to a fresh
        // population so the export still produces a video.
        var selectedProgress: AIGameProgress? = nil
        if selectedScene == .aigame, let id = selectedProgressID {
            selectedProgress = try? loadProgress.execute(id: id)
        }
        let progressToSeed = selectedProgress

        isSheetPresented = false
        autoDismissTask?.cancel()
        autoDismissTask = nil
        lastCompletedURL = nil
        state = .preparing

        task?.cancel()
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            let stream = self.useCase.execute(audio: audio,
                                              output: selectedOutput,
                                              scene: selectedScene,
                                              palette: palette,
                                              options: options,
                                              aiGameProgress: progressToSeed)
            for await s in stream {
                self.state = s
                if case .completed(let url) = s {
                    self.lastCompletedURL = url
                    self.scheduleAutoDismiss()
                }
            }
        }
    }

    func cancel() {
        task?.cancel()
    }

    private func scheduleAutoDismiss() {
        autoDismissTask?.cancel()
        autoDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, !Task.isCancelled else { return }
            if case .completed = self.state {
                self.state = nil
                self.lastCompletedURL = nil
            }
        }
    }
}
