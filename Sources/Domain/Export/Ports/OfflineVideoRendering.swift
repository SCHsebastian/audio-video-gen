import Foundation

/// Off-line variant of `VisualizationRendering`. Where the live port pushes
/// analyser output into a continuously-running MTKView, this port frames a
/// finite encoding session: `begin` opens the writer, every `consume` encodes
/// one video frame, and either `finish` or `cancel` closes it.
///
/// Order-of-calls contract: `begin` exactly once, `consume` zero-or-more times,
/// then exactly one of `finish` or `cancel`. Calling out of order throws
/// `ExportError.encoderFailed`. `cancel` is idempotent and safe to call from
/// any state — it tears down the writer cleanly and deletes the partial file.
public protocol OfflineVideoRendering: AnyObject, Sendable {
    func begin(output: URL, options: RenderOptions, scene: SceneKind, palette: ColorPalette) throws

    /// `async` so the implementation can suspend when the encoder's input is
    /// not yet ready for more media — this is the backpressure mechanism.
    /// Throws if the writer enters `.failed` mid-stream.
    func consume(spectrum: SpectrumFrame, waveform: WaveformBuffer, beat: BeatEvent?, dt: Float) async throws

    /// Flushes the encoder and returns the final output URL.
    func finish() async throws -> URL

    /// Aborts the encoding session, deletes the partial output file, and
    /// releases all resources. Safe to call multiple times.
    func cancel() async
}
