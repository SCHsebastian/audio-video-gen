import Foundation
import Domain
import os.lock

/// Fan-out adapter: behaves as a `VisualizationRendering` but broadcasts every
/// audio-frame `consume(...)` to *every* registered concrete renderer. Used
/// by the split-view mode so the second canvas's renderer receives the same
/// audio without re-running the capture pipeline.
///
/// `setScene` and `setPalette` are intentionally **not** fanned out — those
/// are per-window decisions made by each view-model directly against its own
/// renderer. The bus only deals with the audio-stream side of the protocol.
final class RenderBus: VisualizationRendering, @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: [MetalVisualizationRenderer]())

    func register(_ r: MetalVisualizationRenderer) {
        lock.withLock { consumers in
            if !consumers.contains(where: { $0 === r }) { consumers.append(r) }
        }
    }

    func unregister(_ r: MetalVisualizationRenderer) {
        lock.withLock { consumers in
            consumers.removeAll { $0 === r }
        }
    }

    func consume(spectrum: SpectrumFrame, waveform: [Float], beat: BeatEvent?) {
        let snapshot = lock.withLock { $0 }
        for r in snapshot { r.consume(spectrum: spectrum, waveform: waveform, beat: beat) }
    }

    // Per-renderer concerns — no-ops here. Owning view-models talk to their
    // renderer directly.
    func setScene(_ kind: SceneKind) {}
    func setPalette(_ palette: ColorPalette) {}
}
