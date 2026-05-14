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

    let localizer: BundleLocalizer
    private let useCase: ExportVisualizationUseCase
    private var task: Task<Void, Never>? = nil
    private var autoDismissTask: Task<Void, Never>? = nil

    init(useCase: ExportVisualizationUseCase, localizer: BundleLocalizer) {
        self.useCase = useCase
        self.localizer = localizer
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
                                              options: options)
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
