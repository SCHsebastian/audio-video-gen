import Domain

public struct StartVisualizationUseCase: Sendable {
    private let capture: SystemAudioCapturing
    private let analyzer: AudioSpectrumAnalyzing
    private let beats: BeatDetecting
    private let renderer: VisualizationRendering
    private let permissions: PermissionRequesting
    private let waveformSampleCount: Int

    public init(capture: SystemAudioCapturing,
                analyzer: AudioSpectrumAnalyzing,
                beats: BeatDetecting,
                renderer: VisualizationRendering,
                permissions: PermissionRequesting,
                waveformSampleCount: Int = 1024) {
        self.capture = capture; self.analyzer = analyzer; self.beats = beats
        self.renderer = renderer; self.permissions = permissions
        self.waveformSampleCount = waveformSampleCount
    }

    public func execute(source: AudioSource) async -> AsyncStream<VisualizationState> {
        AsyncStream { continuation in
            let task = Task {
                let perm = await permissions.current()
                guard perm == .granted else {
                    continuation.yield(.waitingForPermission)
                    continuation.finish()
                    return
                }
                do {
                    let frames = try await capture.start(source: source)
                    continuation.yield(.running)
                    for await frame in frames {
                        let spectrum = analyzer.analyze(frame)
                        let beat = beats.feed(spectrum)
                        let mono = Array(frame.samples.suffix(waveformSampleCount))
                        // Pass real stereo tails when the capture source supplied them.
                        // Mono sources leave `left`/`right` empty, in which case
                        // WaveformBuffer mirrors the mono mixdown.
                        let leftTail  = frame.left.isEmpty  ? nil : Array(frame.left.suffix(waveformSampleCount))
                        let rightTail = frame.right.isEmpty ? nil : Array(frame.right.suffix(waveformSampleCount))
                        let wave = WaveformBuffer(mono: mono, left: leftTail, right: rightTail)
                        renderer.consume(spectrum: spectrum, waveform: wave, beat: beat)
                    }
                    continuation.finish()
                } catch let e as CaptureError {
                    continuation.yield(.error(e))
                    continuation.finish()
                } catch {
                    continuation.yield(.error(.tapCreationFailed(0)))
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
