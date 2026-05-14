import Domain
import Foundation

/// Offline analogue of `StartVisualizationUseCase`. Pulls audio from a file via
/// `AudioFileDecoding`, runs the same analyser + beat detector the live pipe
/// uses, and pushes the result into an `OfflineVideoRendering` adapter that
/// owns its own AVAssetWriter + offscreen Metal target.
public struct ExportVisualizationUseCase: Sendable {
    private let decoder: AudioFileDecoding
    private let analyzer: AudioSpectrumAnalyzing
    private let beats: BeatDetecting
    private let renderer: OfflineVideoRendering
    private let waveformSampleCount: Int

    public init(decoder: AudioFileDecoding,
                analyzer: AudioSpectrumAnalyzing,
                beats: BeatDetecting,
                renderer: OfflineVideoRendering,
                waveformSampleCount: Int = 1024) {
        self.decoder = decoder
        self.analyzer = analyzer
        self.beats = beats
        self.renderer = renderer
        self.waveformSampleCount = waveformSampleCount
    }

    public func execute(audio: URL,
                        output: URL,
                        scene: SceneKind,
                        palette: ColorPalette,
                        options: RenderOptions) -> AsyncStream<ExportState> {
        AsyncStream { continuation in
            let task = Task {
                continuation.yield(.preparing)

                // Best-effort total — used only for the progress chip's
                // percentage. An unknown total yields a nil totalFrames in the
                // streamed state so the UI can fall back to indeterminate.
                let totalAudioFrames: Int?
                do {
                    totalAudioFrames = try await decoder.estimatedFrameCount(url: audio)
                } catch {
                    totalAudioFrames = nil
                }
                let totalVideoFrames: Int? = totalAudioFrames.map { Int(Double($0) / 48_000.0 * Double(options.fps)) }

                let stream: AsyncThrowingStream<AudioFrame, Error>
                do {
                    stream = try decoder.decode(url: audio)
                } catch {
                    continuation.yield(.failed(.fileUnreadable(audio, description: String(describing: error))))
                    continuation.finish()
                    return
                }

                do {
                    try renderer.begin(output: output, options: options, scene: scene, palette: palette)
                } catch let e as ExportError {
                    continuation.yield(.failed(e))
                    continuation.finish()
                    return
                } catch {
                    continuation.yield(.failed(.outputUnwritable(output, description: String(describing: error))))
                    continuation.finish()
                    return
                }

                let audioStep = 1024.0 / 48_000.0
                let videoStep = 1.0 / Double(options.fps)
                var audioTime = 0.0
                var nextVideoTime = 0.0
                var frameIndex = 0
                var lastSpectrum: SpectrumFrame? = nil
                var lastWaveform: WaveformBuffer? = nil
                var lastBeat: BeatEvent? = nil

                do {
                    for try await audioFrame in stream {
                        if Task.isCancelled { break }
                        let spectrum = analyzer.analyze(audioFrame)
                        let beat = beats.feed(spectrum)
                        let mono = Array(audioFrame.samples.suffix(waveformSampleCount))
                        let leftTail  = audioFrame.left.isEmpty  ? nil : Array(audioFrame.left.suffix(waveformSampleCount))
                        let rightTail = audioFrame.right.isEmpty ? nil : Array(audioFrame.right.suffix(waveformSampleCount))
                        lastSpectrum = spectrum
                        lastBeat = beat
                        lastWaveform = WaveformBuffer(mono: mono, left: leftTail, right: rightTail)
                        audioTime += audioStep

                        while nextVideoTime + 1e-9 <= audioTime {
                            if Task.isCancelled { break }
                            guard let s = lastSpectrum, let w = lastWaveform else { break }
                            try await renderer.consume(spectrum: s, waveform: w, beat: lastBeat,
                                                       dt: Float(videoStep))
                            frameIndex &+= 1
                            nextVideoTime = Double(frameIndex) * videoStep
                            if frameIndex % options.fps == 0 {
                                continuation.yield(.rendering(framesEncoded: frameIndex, totalFrames: totalVideoFrames))
                            }
                        }
                    }

                    if Task.isCancelled {
                        await renderer.cancel()
                        continuation.yield(.cancelled)
                        continuation.finish()
                        return
                    }

                    // Drain — emit one trailing frame if the loop ended with
                    // residual audio time that didn't cross a video step.
                    if let s = lastSpectrum, let w = lastWaveform, audioTime > nextVideoTime - 1e-9 {
                        try await renderer.consume(spectrum: s, waveform: w, beat: lastBeat,
                                                   dt: Float(videoStep))
                        frameIndex &+= 1
                    }

                    continuation.yield(.finalising)
                    let url = try await renderer.finish()
                    continuation.yield(.completed(url))
                    continuation.finish()
                } catch let e as ExportError {
                    await renderer.cancel()
                    continuation.yield(.failed(e))
                    continuation.finish()
                } catch {
                    await renderer.cancel()
                    continuation.yield(.failed(.encoderFailed(description: String(describing: error))))
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

public enum ExportState: Equatable, Sendable {
    case preparing
    case rendering(framesEncoded: Int, totalFrames: Int?)
    case finalising
    case completed(URL)
    case failed(ExportError)
    case cancelled
}
