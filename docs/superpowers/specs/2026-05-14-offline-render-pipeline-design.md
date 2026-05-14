# Offline render pipeline — design

**Date:** 2026-05-14
**Status:** Approved direction; awaiting spec review before plan-writing.

## Goal

Export the existing live Metal visualizer as a silent `.mp4` video file driven by any user-picked audio file (mp3 / wav / m4a / aac / flac). Same eleven scenes, same eleven palettes, same analyzer + beat detector. Output is video-only — the source audio is *not* embedded.

Throughput is the primary success metric: a one-minute audio file should produce a one-minute 1080p60 video in considerably less than one minute on Apple silicon.

## Non-goals

- Embedding the audio track in the output (explicit user direction).
- Auto-shuffle / multi-scene exports — single scene per export.
- Editing, trimming, or per-section palette changes — the picker captures one scene + one palette for the whole duration.
- An offline-render CLI binary — in-app only.
- Rendering anything other than the eleven existing scenes.
- HDR / wider colour primaries — stick to BT.709.

## Decisions (locked from brainstorming)

| Question | Choice |
|---|---|
| Trigger | In-app **Export…** toolbar button |
| Scene + palette | Picked in the export sheet, independent of the live preview |
| Resolution + fps | Picker in the sheet: 720p / 1080p / 4K × 30 fps / 60 fps |
| Format | H.264 in `.mp4` (hardware encoder via VideoToolbox) |
| Progress UX | Modal sheet dismisses on Start; render runs in the background; a toolbar progress chip shows percent + Cancel |
| Mute | No audio track in the output |

## Architecture (Approach B from the proposal)

A new offline pipeline running parallel to the live pipeline. Shares the Metal device, command queue, and library with the primary renderer; everything else is independent. Live rendering is untouched.

```
                    ┌────────────────────┐
   user URL ──────► │ AVAudioFileDecoder │ ──► AsyncStream<AudioFrame>
                    └────────────────────┘
                            │
                            ▼
                    ┌────────────────────┐
                    │ VDSPSpectrumAnal.  │ (reused, unchanged)
                    │ EnergyBeatDetector │ (reused, unchanged)
                    └────────────────────┘
                            │
                            ▼  SpectrumFrame, WaveformBuffer, BeatEvent
                    ┌────────────────────┐
                    │ AVOfflineRenderer  │
                    │  (scene cache,     │
                    │   shared device,   │
                    │   AVAssetWriter)   │
                    └────────────────────┘
                            │
                            ▼
                       silent .mp4
```

### Domain (new ports)

`Sources/Domain/Export/Ports/AudioFileDecoding.swift`

```swift
public protocol AudioFileDecoding: Sendable {
    /// Decode `url` to 48 kHz Float32 interleaved stereo and yield 1024-frame
    /// `AudioFrame`s with mono mixdown + left + right channels — same contract
    /// the live capture publishes. Yields `nil`-terminated when EOF is reached.
    /// Throws on unreadable files or unsupported codecs.
    func decode(url: URL) throws -> AsyncThrowingStream<AudioFrame, Error>

    /// Total frame count at 48 kHz for progress reporting. Returns `nil` if the
    /// duration cannot be determined cheaply (rare; mp3 with no Xing header).
    func estimatedFrameCount(url: URL) async throws -> Int?
}
```

`Sources/Domain/Export/Ports/OfflineVideoRendering.swift`

```swift
public protocol OfflineVideoRendering: AnyObject, Sendable {
    func begin(output: URL, options: RenderOptions, scene: SceneKind, palette: ColorPalette) throws

    /// `consume` is `async` so the implementation can suspend when the encoder's
    /// input is not yet ready for more media — this is the backpressure mechanism.
    /// Throws if the writer enters `.failed` mid-stream.
    func consume(spectrum: SpectrumFrame, waveform: WaveformBuffer, beat: BeatEvent?, dt: Float) async throws

    func finish() async throws -> URL
    func cancel() async
}
```

Order-of-calls contract: `begin` exactly once, `consume` zero-or-more times, then exactly one of `finish` or `cancel`. Calling out of order throws `ExportError.encoderFailed` (programmer error). `cancel` is idempotent and safe to call from any state.

`Sources/Domain/Export/ValueObjects/RenderOptions.swift`

```swift
public struct RenderOptions: Equatable, Sendable {
    public let width: Int          // 1280, 1920, 3840
    public let height: Int         // 720, 1080, 2160
    public let fps: Int            // 30 or 60
    public let bitrate: Int        // derived from resolution × fps (see § Defaults)
}
```

`SceneKind`, `ColorPalette`, `SpectrumFrame`, `WaveformBuffer`, `BeatEvent`, `AudioFrame` — all reused as-is.

### Application (new use case)

`Sources/Application/UseCases/ExportVisualizationUseCase.swift` mirrors `StartVisualizationUseCase`:

```swift
public struct ExportVisualizationUseCase: Sendable {
    public init(decoder: AudioFileDecoding,
                analyzer: AudioSpectrumAnalyzing,
                beats: BeatDetecting,
                renderer: OfflineVideoRendering)

    public func execute(audio: URL,
                        output: URL,
                        scene: SceneKind,
                        palette: ColorPalette,
                        options: RenderOptions) -> AsyncStream<ExportState>
}

public enum ExportState: Equatable, Sendable {
    case preparing
    case rendering(framesEncoded: Int, totalFrames: Int?)
    case finalising
    case completed(URL)
    case failed(ExportError)
    case cancelled
}
```

The use case owns the read loop: pull `AudioFrame` from the decoder, feed analyzer + beat detector, hand the resulting `SpectrumFrame` / `WaveformBuffer` / `BeatEvent` to the renderer along with a fixed `dt = 1/fps`. Progress is yielded every `fps`-th frame (≈ once per output-video second) to keep UI updates cheap.

Cancellation: the stream's `onTermination` calls `renderer.cancel()`, which calls `AVAssetWriter.cancelWriting()` (clean teardown + deletes the partial file).

### Infrastructure (two new adapters)

**`AudioVisualizer/Infrastructure/Export/AVAudioFileDecoder.swift`** — implements `AudioFileDecoding`.

- `AVURLAsset` + `AVAssetReader` + `AVAssetReaderTrackOutput`.
- Output settings hardcode 48 kHz Float32 interleaved stereo (resampled at the reader boundary by Core Audio's converter — free on Apple silicon). Matches the live capture's contract bit-for-bit, so downstream code doesn't care that the source is a file.
- Per `copyNextSampleBuffer()`: pull the `CMSampleBuffer`'s `AudioBufferList`, walk the interleaved Float32, deinterleave with vDSP into L/R scratch buffers, accumulate into 1024-frame `AudioFrame`s with the mono mixdown precomputed. Final partial chunk is zero-padded so the renderer always sees full chunks (matches live).

**`AudioVisualizer/Infrastructure/Export/AVOfflineVideoRenderer.swift`** — implements `OfflineVideoRendering`.

- Built via a factory that takes the primary renderer's `MTLDevice`, `MTLCommandQueue`, and `MTLLibrary` (`makeOfflineRenderer(...)` on `MetalVisualizationRenderer`, mirroring the existing `makeSecondary(...)`).
- Owns its own `scenes: [SceneKind: VisualizerScene]` cache, populated lazily via the same `sceneBuilders` the live renderer uses.
- `begin(output:options:scene:palette:)` opens an `AVAssetWriter` at `output` with:
  - `AVAssetWriterInput` for video, settings:
    - `AVVideoCodecKey: .h264`
    - `AVVideoWidthKey / HeightKey` from options
    - `AVVideoCompressionPropertiesKey`: average bit rate (table below), `AVVideoMaxKeyFrameIntervalKey: fps × 2` (2 s GOP), `AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel`, `AVVideoAllowFrameReorderingKey: true`, `AVVideoExpectedSourceFrameRateKey: fps`.
    - `AVVideoColorPropertiesKey`: BT.709 primaries / transfer / matrix.
  - `AVAssetWriterInputPixelBufferAdaptor` with source attributes:
    - `kCVPixelFormatType_32BGRA`
    - `kCVPixelBufferIOSurfacePropertiesKey: [:]` and `kCVPixelBufferMetalCompatibilityKey: true` so pool buffers can be bound directly as Metal textures.
  - Builds a `CVMetalTextureCache` once, alive for the writer's lifetime.
- `consume(...)`:
  1. Acquire a `CVPixelBuffer` from `adaptor.pixelBufferPool` (auto-sized by AVFoundation; typically 3-deep).
  2. Bind it as an `MTLTexture` via `CVMetalTextureCacheCreateTextureFromImage` (zero-copy through the shared IOSurface).
  3. Build a per-frame `MTLRenderPassDescriptor` pointing at that texture, encode the scene's `update` + `encode`, commit the command buffer.
  4. In the buffer's `addCompletedHandler`, call `adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: frameIndex, timescale: Int32(fps)))` and bump `frameIndex`. **No `waitUntilCompleted`.** The pool's natural buffer depth + `isReadyForMoreMediaData` give us the right backpressure.
  5. If `isReadyForMoreMediaData == false`, sleep the *use-case's* loop (an `AsyncStream<Void>` driven by `requestMediaDataWhenReady`) until the encoder catches up. This keeps the render thread free of busy-waits.
- `finish()` calls `input.markAsFinished()` then awaits `writer.finishWriting()`; returns the output URL.
- `cancel()` calls `writer.cancelWriting()` (deletes the partial file per `AVAssetWriter.h`) and tears down the texture cache.

### Presentation

**`ExportSheetView`** — toolbar's new "Export…" button presents this as a `.sheet`. Form layout (same conventions as `SettingsView`):
- Audio file picker (`NSOpenPanel` via `Button("Choose audio file…")`; accepted UTI list = `public.audio`).
- Scene picker (`Menu`, mirrors `SceneToolbar` styling).
- Palette picker (Picker over `PaletteFactory.all`).
- Resolution picker (`Picker`: 720p / 1080p / 4K).
- FPS picker (`Picker`: 30 / 60).
- Output location button (`NSSavePanel`; default name = `<audio-basename>.mp4`).
- Cancel + Start buttons.

On Start: the view model invokes `exportUseCase.execute(...)`, the sheet dismisses immediately, and a **toolbar progress chip** appears (new `ExportProgressChip` view) showing `frames / total` percent + a Cancel `xmark.circle` button. Tapping Cancel sets a flag the use case checks and terminates its stream → renderer's `onTermination` runs.

The chip stays for ~3 seconds after `.completed` showing "Done — Reveal in Finder" (links via `NSWorkspace.activateFileViewerSelecting`). On `.failed`, the chip shows an `xmark.octagon.fill` with a tooltip describing the error.

**`ExportViewModel`** (`@Observable`) — fields: `state: ExportState = .idle`, `currentURL: URL?`. Holds a `Task?` for the running export so Cancel can `task.cancel()`. Subscribes to `for await state in exportUseCase.execute(...)` and assigns each yielded state to `self.state` on the main actor.

**CompositionRoot wiring** adds:

```swift
let decoder = AVAudioFileDecoder()
let offlineRenderer = MetalVisualizationRenderer.makeOfflineRenderer(
    device: primaryRenderer.deviceForSecondary,
    queue:  primaryRenderer.queueForSecondary,
    library: primaryRenderer.libraryForSecondary)
let exportUseCase = ExportVisualizationUseCase(
    decoder: decoder, analyzer: analyzer, beats: beats, renderer: offlineRenderer)
let exportVM = ExportViewModel(useCase: exportUseCase, localizer: localizer)
```

The view model is injected into `RootView` alongside `VisualizerViewModel`.

## Defaults

| Resolution | fps | Bit rate target |
|---|---|---|
| 1280×720 | 30 | 5 Mbps |
| 1280×720 | 60 | 7.5 Mbps |
| 1920×1080 | 30 | 8 Mbps |
| 1920×1080 | 60 | 12 Mbps |
| 3840×2160 | 30 | 30 Mbps |
| 3840×2160 | 60 | 45 Mbps |

GOP = `fps × 2` for all rows. Profile = High AutoLevel. B-frames on (we're offline, latency doesn't matter).

`dt = 1 / fps` exactly. PTS = `CMTime(value: frameIndex, timescale: Int32(fps))` — integer time, no float drift.

## Audio ↔ video frame coupling

Audio frames are 1024 samples at 48 kHz = 21.33 ms each. Video frames are 1/fps apart (16.67 ms at 60 fps, 33.33 ms at 30 fps). The rates don't divide evenly, so the use case decouples them with a running "audio time consumed" cursor:

```swift
let audioStep = 1024.0 / 48_000.0    // 0.0213 s
let videoStep = 1.0 / Double(fps)
var audioTime = 0.0
var nextVideoTime = 0.0
var frameIndex = 0
var lastSpectrum = SpectrumFrame.silent
var lastWaveform = WaveformBuffer.silent
var lastBeat: BeatEvent? = nil

for try await audioFrame in decoder.decode(url) {
    lastSpectrum = analyzer.analyze(audioFrame)
    lastBeat     = beats.feed(lastSpectrum)
    lastWaveform = WaveformBuffer(mono: audioFrame.samples, left: audioFrame.left, right: audioFrame.right)
    audioTime += audioStep
    while nextVideoTime + 1e-9 <= audioTime {
        try renderer.consume(spectrum: lastSpectrum, waveform: lastWaveform, beat: lastBeat,
                             dt: Float(videoStep))
        frameIndex += 1
        nextVideoTime = Double(frameIndex) * videoStep
    }
}
// Drain: emit one trailing video frame if any partial audio is left.
```

Result: each video frame consumes the most recent analyzer + beat output. Long audio files don't accumulate drift because `nextVideoTime` is recomputed from the integer `frameIndex` every step.

## Scene determinism

Scenes are built fresh per export — the offline renderer's scene cache is independent of the live one. No `randomize()` is called, so every export starts from the scene's deterministic default knobs (e.g. `TunnelScene.direction = 1.0`, `LissajousScene.modeIsRose = false`). Exporting the same audio + scene + palette + resolution + fps twice produces visually identical files. v0 ships without a "randomize before export" toggle; future work can add one.

## Concurrency model

- The use case runs on a detached `Task`. The decoder, analyzer, beat detector, and renderer all execute on that task.
- The Metal command queue is shared with the live renderer. Both renderers can submit concurrently; Metal serialises submissions per-queue. Offline encodes typically run at GPU saturation, so the live preview may stutter mid-export — **acceptable per the brainstorming decision** (background-task export with a toolbar chip; live keeps running but isn't guaranteed smooth).
- AVAssetWriter's input drives backpressure via `requestMediaDataWhenReady`. The use case waits on a small `AsyncStream<Void>` continuation that the renderer fulfils each time the writer's input flips back to ready.
- Cancellation: `Task.cancel()` propagates through the stream loop. The renderer's `cancel()` is idempotent.

## Error model

`ExportError`:
- `.fileUnreadable(URL, underlying: Error)` — `AVAssetReader` failed to open the file.
- `.unsupportedAudioFormat(String)` — file decoded to zero audio tracks or unknown sample format.
- `.outputUnwritable(URL, underlying: Error)` — `AVAssetWriter` failed to start.
- `.encoderFailed(underlying: Error)` — writer entered `.failed` mid-stream.
- `.metalUnavailable` — device lost or texture cache creation failed.

Errors are localised via new `L10nKey` entries (e.g. `export.error.fileUnreadable`) and surfaced via the toolbar chip's tooltip.

## Test plan

**Domain tests** — `Tests/DomainTests/Export/RenderOptionsTests.swift`:
- `test_render_options_holds_dimensions_fps_bitrate`
- `test_render_options_equatable_distinguishes_resolutions`

**Application tests** — `Tests/ApplicationTests/UseCases/ExportVisualizationUseCaseTests.swift`, with new fakes in `Tests/ApplicationTests/Fakes/`:
- `FakeAudioFileDecoding.swift` — yields a scripted sequence of `AudioFrame`s, optionally throws.
- `FakeBeatDetecting.swift`, `FakeOfflineVideoRendering.swift`.
- Cases:
  - `test_when_decoder_yields_frames_renderer_consumes_each_one`
  - `test_when_decoder_throws_emits_failed_state`
  - `test_when_cancelled_calls_renderer_cancel_and_emits_cancelled`
  - `test_progress_state_yields_total_when_estimated_frame_count_known`
  - `test_progress_state_yields_unknown_total_when_estimated_frame_count_nil`

**Infrastructure tests** — `AudioVisualizer/Tests/Infrastructure/`:
- `AVAudioFileDecoderTests.swift`:
  - `test_decodes_known_wav_to_expected_frame_count` (fixture: 48 kHz 1 s sine bundled in test resources)
  - `test_resamples_44_1kHz_source_to_48kHz` (fixture: 44.1 kHz sine; assert decoded frame count ≈ duration × 48000 within tolerance)
  - `test_yields_mono_mixdown_matching_l_r_average`
  - `test_throws_on_nonexistent_file`
- `AVOfflineVideoRendererTests.swift`:
  - `test_renders_one_second_of_silence_to_existing_file` (asserts AVURLAsset can read it back, video track exists at the requested fps × duration frame count, no audio track present)
  - `test_cancel_deletes_partial_file`

## Out of scope (future work)

- Audio embedding (would need a second `AVAssetWriterInput` for audio + careful PTS alignment).
- Multi-scene auto-shuffle in a single export.
- Per-export randomize() seed control for deterministic re-renders.
- CLI binary.
- HDR / wider colour spaces.

## Files added (no edits to existing live code paths)

```
Sources/Domain/Export/Ports/AudioFileDecoding.swift
Sources/Domain/Export/Ports/OfflineVideoRendering.swift
Sources/Domain/Export/ValueObjects/RenderOptions.swift
Sources/Domain/Export/ValueObjects/ExportError.swift
Sources/Application/UseCases/ExportVisualizationUseCase.swift
AudioVisualizer/Infrastructure/Export/AVAudioFileDecoder.swift
AudioVisualizer/Infrastructure/Export/AVOfflineVideoRenderer.swift
AudioVisualizer/Presentation/ViewModels/ExportViewModel.swift
AudioVisualizer/Presentation/Scenes/ExportSheetView.swift
AudioVisualizer/Presentation/Scenes/ExportProgressChip.swift
Tests/DomainTests/Export/RenderOptionsTests.swift
Tests/ApplicationTests/UseCases/ExportVisualizationUseCaseTests.swift
Tests/ApplicationTests/Fakes/FakeAudioFileDecoding.swift
Tests/ApplicationTests/Fakes/FakeBeatDetecting.swift
Tests/ApplicationTests/Fakes/FakeOfflineVideoRendering.swift
AudioVisualizer/Tests/Infrastructure/AVAudioFileDecoderTests.swift
AudioVisualizer/Tests/Infrastructure/AVOfflineVideoRendererTests.swift
```

Existing files touched (additive only): `CompositionRoot.swift`, `MetalVisualizationRenderer.swift` (new `makeOfflineRenderer` factory), `RootView.swift` (toolbar button + chip), `L10nKey.swift` + `Localizable.xcstrings` (new strings), `project.yml` (new sources), and a new sub-folder for the test fixture audio files.
