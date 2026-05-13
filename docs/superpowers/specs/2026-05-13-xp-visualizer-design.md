# XP-Style System Audio Visualizer — Design Spec

**Date:** 2026-05-13
**Status:** Draft for review
**Author:** Pair (Sebastián + Claude)

## 1. Purpose

A native macOS app that captures the system's audio **output** (not the microphone) and renders Windows XP Media Player-style real-time visualizations. The user picks a running app (or "all system audio"), grants a one-time permission, picks a visualization, and watches their music turn into light.

**Non-goals for v1**

- Recording or saving audio/video.
- Playback control of source apps.
- Plugin SDK for third-party visualizations.
- iOS / iPadOS support.
- Pre-macOS 14.2 fallback (we explicitly target the Core Audio Taps era).

## 2. Constraints

- macOS 14.2+ (Core Audio Taps API), Apple Silicon and Intel.
- No virtual audio device install (no BlackHole, no kext).
- No microphone use.
- One-time TCC consent ("Audio Capture") only.
- Keep the codebase small and readable; this is a dev tool, not enterprise software.

## 3. Tech stack

- **Language:** Swift 5.10+.
- **UI:** SwiftUI (NSViewRepresentable wrapping an MTKView for the canvas).
- **Capture:** Core Audio Taps (`CATapDescription`, `AudioHardwareCreateProcessTap`, private aggregate device).
- **Analysis:** `Accelerate.framework` (`vDSP_DFT_zrop_*`, Hann window, magnitude/dB).
- **Render:** Metal + MetalKit. Compute shaders for particles, vertex/fragment for bars and scope.
- **Ring buffer:** `TPCircularBuffer` (Michael Tyson, BSD, vendored as a tiny SwiftPM target).
- **Persistence:** `UserDefaults` for "last selected scene" and "last selected audio source".
- **Build:** Swift Package Manager workspace + Xcode project for the app target (so we can ship a signed `.app`).

## 4. Architecture: Clean Architecture + DDD (mobile flavor, kept small)

### 4.1 Layers and direction

```
Presentation  ─►  Application  ─►  Domain  ◄─  Infrastructure
                                              ▲
                                    App (Composition Root)
```

- **Domain** — pure Swift, zero Apple-framework imports. Entities, value objects, errors, port protocols.
- **Application** — use cases. Orchestrates ports. No SwiftUI, no Metal, no Core Audio.
- **Infrastructure** — concrete adapters that implement Domain ports. This is where Core Audio, vDSP, Metal, and `UserDefaults` live.
- **Presentation** — SwiftUI views and `@Observable` view models. Talks only to use cases.
- **App / Composition Root** — `@main` struct + a single `CompositionRoot.swift` that constructs adapters and wires use cases.

### 4.2 Bounded contexts

1. **Audio Capture** — process discovery, tap lifecycle, PCM stream out.
2. **Audio Analysis** — FFT, RMS, simple beat (energy-threshold) detection.
3. **Visualization** — scene catalogue, palette, renderer.
4. **Preferences** — last source, last scene, last palette.

Plus a tiny **Shared Kernel** (`Domain/Shared/`) for cross-context value types: `AudioFrame`, `SampleRate`, `HostTime`, `RGB`.

### 4.3 Ports (Domain) → Adapters (Infrastructure)

| Port | Adapter | Bounded context |
|---|---|---|
| `SystemAudioCapturing` | `CoreAudioTapCapture` | Capture |
| `ProcessDiscovering` | `RunningApplicationsDiscovery` | Capture |
| `PermissionRequesting` | `TCCAudioCapturePermission` | Capture |
| `AudioSpectrumAnalyzing` | `VDSPSpectrumAnalyzer` | Analysis |
| `BeatDetecting` | `EnergyBeatDetector` | Analysis |
| `VisualizationRendering` | `MetalVisualizationRenderer` | Visualization |
| `PreferencesStoring` | `UserDefaultsPreferences` | Preferences |

### 4.4 Folder layout

```
audio-video-gen/
  Package.swift                            # SwiftPM workspace (Domain + Application as libs)
  AudioVisualizer.xcodeproj/               # App target + Infra + Presentation
  AudioVisualizer/                         # App sources
    Domain/
      Shared/
        AudioFrame.swift
        SampleRate.swift
        HostTime.swift
        RGB.swift
      AudioCapture/
        ValueObjects/AudioSource.swift
        ValueObjects/AudioProcessInfo.swift
        Errors/CaptureError.swift
        Ports/SystemAudioCapturing.swift
        Ports/ProcessDiscovering.swift
        Ports/PermissionRequesting.swift
      AudioAnalysis/
        ValueObjects/FrequencyBand.swift
        ValueObjects/BeatEvent.swift
        ValueObjects/SpectrumFrame.swift
        Ports/AudioSpectrumAnalyzing.swift
        Ports/BeatDetecting.swift
      Visualization/
        ValueObjects/SceneKind.swift
        ValueObjects/ColorPalette.swift
        Errors/RenderError.swift
        Ports/VisualizationRendering.swift
      Preferences/
        ValueObjects/UserPreferences.swift
        Ports/PreferencesStoring.swift
    Application/
      UseCases/
        StartVisualizationUseCase.swift
        StopVisualizationUseCase.swift
        SelectAudioSourceUseCase.swift
        ChangeSceneUseCase.swift
        ListAudioSourcesUseCase.swift
    Infrastructure/
      CoreAudio/
        CoreAudioTapCapture.swift
        RingBuffer.swift                   # Swift wrapper around TPCircularBuffer
        AudioObjectID+Properties.swift
        RunningApplicationsDiscovery.swift
        TCCAudioCapturePermission.swift
      Analysis/
        VDSPSpectrumAnalyzer.swift
        EnergyBeatDetector.swift
      Metal/
        MetalVisualizationRenderer.swift
        Renderer/
          MetalDevice.swift
          PingPongTextures.swift
          PaletteTexture.swift
        Scenes/
          BarsScene.swift
          ScopeScene.swift
          AlchemyScene.swift
        Shaders/
          Bars.metal
          Scope.metal
          AlchemyParticles.metal
          Feedback.metal
      Persistence/
        UserDefaultsPreferences.swift
    Presentation/
      Scenes/
        RootView.swift
        VisualizerView.swift
        MetalCanvas.swift                  # NSViewRepresentable wrapping MTKView
        SourcePicker.swift
        SceneToolbar.swift
        PermissionGate.swift
      ViewModels/
        VisualizerViewModel.swift          # @Observable
        SourcePickerViewModel.swift
    App/
      VisualizerApp.swift                  # @main
      CompositionRoot.swift
    Resources/
      Info.plist
      AudioVisualizer.entitlements
  Vendor/
    TPCircularBuffer/                      # vendored, BSD
  Tests/
    DomainTests/
    ApplicationTests/
    InfrastructureTests/
```

## 5. Domain model

### 5.1 Shared kernel

```swift
// Domain/Shared/SampleRate.swift
public struct SampleRate: Equatable, Hashable { public let hz: Double }

// Domain/Shared/HostTime.swift
public struct HostTime: Equatable { public let machAbsolute: UInt64 }

// Domain/Shared/RGB.swift
public struct RGB: Equatable { public let r, g, b: Float }

// Domain/Shared/AudioFrame.swift  (owns its samples — copied out of the IOProc)
public struct AudioFrame {
    public let samples: [Float]      // mono mixdown for analysis simplicity
    public let sampleRate: SampleRate
    public let timestamp: HostTime
}
```

### 5.2 Capture context

```swift
public enum AudioSource: Equatable {
    case systemWide                       // tap all processes
    case process(pid: pid_t, bundleID: String)
}

public struct AudioProcessInfo: Equatable {
    public let pid: pid_t
    public let bundleID: String
    public let displayName: String
    public let isProducingAudio: Bool
}

public enum CaptureError: Error, Equatable {
    case permissionDenied
    case permissionUndetermined
    case processNotFound(pid_t)
    case formatUnsupported(description: String)
    case tapCreationFailed(OSStatus)
    case aggregateDeviceCreationFailed(OSStatus)
    case ioProcStartFailed(OSStatus)
    case defaultOutputDeviceUnavailable
}

public protocol SystemAudioCapturing {
    func start(source: AudioSource) async throws -> AsyncStream<AudioFrame>
    func stop() async
}

public protocol ProcessDiscovering {
    func listAudioProcesses() async throws -> [AudioProcessInfo]
}

public enum PermissionState: Equatable { case undetermined, granted, denied }
public protocol PermissionRequesting {
    func current() async -> PermissionState
    func request() async -> PermissionState
}
```

### 5.3 Analysis context

```swift
public struct SpectrumFrame {
    public let bands: [Float]            // magnitudes, normalized 0..1, length == bandCount
    public let rms: Float                // overall loudness 0..1
    public let timestamp: HostTime
}

public struct BeatEvent { public let timestamp: HostTime; public let strength: Float }

public protocol AudioSpectrumAnalyzing {
    var bandCount: Int { get }
    func analyze(_ frame: AudioFrame) -> SpectrumFrame
}

public protocol BeatDetecting {
    func feed(_ spectrum: SpectrumFrame) -> BeatEvent?
}
```

### 5.4 Visualization context

```swift
public enum SceneKind: String, CaseIterable, Equatable {
    case bars       // classic XP "Bars" spectrum analyzer
    case scope      // oscilloscope waveform
    case alchemy    // particle field, reacts to bass
}

public struct ColorPalette: Equatable {
    public let name: String
    public let stops: [RGB]              // sampled into a 1×256 texture
}

public enum RenderError: Error, Equatable {
    case metalDeviceUnavailable
    case shaderCompilationFailed(name: String)
    case pipelineCreationFailed(name: String)
}

public protocol VisualizationRendering: AnyObject {
    func setScene(_ kind: SceneKind)
    func setPalette(_ palette: ColorPalette)
    func consume(spectrum: SpectrumFrame, waveform: [Float], beat: BeatEvent?)
}
```

### 5.5 Preferences context

```swift
public struct UserPreferences: Equatable {
    public var lastSource: AudioSource
    public var lastScene: SceneKind
    public var lastPaletteName: String
}

public protocol PreferencesStoring {
    func load() -> UserPreferences
    func save(_ prefs: UserPreferences)
}
```

## 6. Application: use cases

Each use case takes its dependencies in `init`, exposes one async method, and returns either a stream or a value.

- **`ListAudioSourcesUseCase`** — wraps `ProcessDiscovering`. Returns `[AudioProcessInfo] + systemWide` for the picker.
- **`SelectAudioSourceUseCase`** — saves the choice via `PreferencesStoring`.
- **`StartVisualizationUseCase`** — orchestrates: check `PermissionRequesting` → start `SystemAudioCapturing` → for each `AudioFrame`, run `AudioSpectrumAnalyzing` + `BeatDetecting` → push `SpectrumFrame + waveform + beat` into `VisualizationRendering`.
- **`StopVisualizationUseCase`** — stops the capture and clears the renderer.
- **`ChangeSceneUseCase`** — `renderer.setScene(...)`, persist preference.

The Start use case returns an `AsyncStream<VisualizationState>` for the view model (state = `.idle | .waitingForPermission | .running | .noAudioYet | .error(DomainError)`). View models render UI off this state.

## 7. Critical concurrency boundary

The Core Audio IOProc callback is **real-time**: no allocations, no Swift runtime calls, no locks, no actors, no logging, no allocations. This is acknowledged explicitly:

- The IOProc lives **only** inside `CoreAudioTapCapture`. It is not a port; nothing else sees it.
- It does exactly one thing: `memcpy` interleaved/non-interleaved float frames into a `TPCircularBuffer` and atomically updates a counter.
- A dedicated `DispatchQueue` (`tap.drain`, `qos: .userInteractive`) pulls fixed-size chunks (1024 frames @ 48 kHz, ~21 ms) from the ring, downmixes to mono, wraps them in `AudioFrame`, and yields into the `AsyncStream<AudioFrame>` continuation.
- The adapter is the **only** place this lie ("Core Audio is async-friendly") is told. The port pretends it's pure async/await.

```
[Audio HW] → IOProc → memcpy → TPCircularBuffer
                                    │
                                    ▼
                       drain queue (DispatchQueue)
                                    │
                                    ▼
                       AsyncStream<AudioFrame> (port boundary)
                                    │
                                    ▼
                       AudioSpectrumAnalyzing (FFT, ~21 ms cadence)
                                    │
                                    ▼
                       VisualizationRendering.consume(...)
                                    │
                                    ▼
                       MTKView draw loop @ 60/120 fps (CADisplayLink)
```

The renderer pulls the **latest** spectrum/waveform from a `lock-protected latest-value slot` inside the Metal adapter — not the AsyncStream — so the render loop never blocks on audio.

## 8. Visualizations (v1)

All three use the same palette texture, the same ping-pong feedback target (subtle trails), and the same `SpectrumFrame + waveform[]` input.

### 8.1 Bars (classic XP)
- 64 vertical bars, log-spaced over 30 Hz – 16 kHz.
- Per-bar exponential decay (`displayed = max(new, displayed * 0.88)`).
- Instanced quad draw, color sampled from palette by bar index.
- Tip "peak markers": floating squares that fall at 1.2 units/sec, reset on new peak.

### 8.2 Scope (oscilloscope)
- Triangle-strip extrusion of the latest 1024 waveform samples across the screen width.
- Thick neon line on top + thicker low-alpha line behind for fake bloom.
- Slight horizontal jitter scaled by RMS for a CRT vibe.

### 8.3 Alchemy (particles)
- 80 000 particles in an `MTLBuffer<Particle>`; compute shader updates positions per frame.
- Force field: radial outward force scaled by bass band magnitude (FFT bins 1–8).
- Beat events trigger a short brightness pulse.
- Additive-blend instanced quad draw, soft-circle sprite.

Each scene conforms to a tiny internal protocol inside `Infrastructure/Metal/`:

```swift
protocol VisualizerScene: AnyObject {
    func build(device: MTLDevice, library: MTLLibrary) throws
    func update(spectrum: SpectrumFrame, waveform: [Float], beat: BeatEvent?, dt: Float)
    func encode(into encoder: MTLRenderCommandEncoder, uniforms: inout SceneUniforms)
}
```

This protocol is **not** a Domain port; it's a private implementation seam owned by the Metal adapter. Switching scenes never tears down `MTLDevice`/`MTLCommandQueue`.

## 9. UI

Two screens, both SwiftUI.

1. **Permission gate** — only shown when `PermissionState == .undetermined` or `.denied`. Big "Grant Audio Capture access" button → on tap, calls `PermissionRequesting.request()`. If `.denied`, shows a "Open System Settings → Privacy → Audio Capture" link with the magic URL.
2. **Main view** — full-window `MetalCanvas` with an auto-hiding top toolbar:
   - source picker (dropdown of `AudioProcessInfo` + "All system audio")
   - scene picker (segmented: Bars / Scope / Alchemy)
   - palette picker (3 presets: "XP Neon", "Aurora", "Sunset")
   - fullscreen toggle
   - small "no audio detected" overlay when `kAudioProcessPropertyIsRunningOutput` is false for the selected process

Window is resizable, defaults to 1280×720, supports fullscreen.

## 10. Error handling

Errors are domain values, never bare `OSStatus` leaking up. The view model maps `CaptureError` cases to user-facing strings:

| Error | UI behavior |
|---|---|
| `permissionDenied` | Show the permission gate with "Open Settings" link |
| `permissionUndetermined` | Show "Grant access" button |
| `processNotFound` | Show "App is no longer running"; auto-fallback to `systemWide` after 3 s |
| `formatUnsupported` | Toast: "This audio format isn't supported"; stop |
| `tapCreationFailed(status)` | Toast with the OSStatus integer; offer "Retry"; if it happens twice, suggest reboot |
| `aggregateDeviceCreationFailed` | Same as above |
| `ioProcStartFailed` | Same |
| `defaultOutputDeviceUnavailable` | Toast: "No audio output device available" |
| `RenderError.metalDeviceUnavailable` | Show a fatal screen: "Your Mac doesn't support Metal." (extremely rare on supported macOS versions) |
| `RenderError.shaderCompilationFailed` | Bug — log to `os_log`, show a developer overlay in DEBUG, generic "Visualization unavailable" in release |

No try/catch swallowing: every adapter throws typed Domain errors; use cases let them bubble; view models switch over them.

## 11. Testing strategy

| Layer | Test type | What's exercised |
|---|---|---|
| Domain | Unit | Value object equality, palette interpolation, scene-kind round-trip |
| Application | Unit with fakes | `FakeCapture` emits canned `AudioFrame`s → assert `StartVisualizationUseCase` produces expected `SpectrumFrame`s |
| Infrastructure / Analysis | Unit | `VDSPSpectrumAnalyzer` against synthesized sine waves at known frequencies — peak band must match |
| Infrastructure / Metal | Smoke | Renderer constructs without throwing on the host Mac; one off-screen frame renders without GPU errors |
| Infrastructure / Core Audio | Manual | Documented script: launch app, play known track in Music.app, verify visualization responds |
| Presentation | Snapshot (optional) | Permission gate states |

`DomainTests/` and `ApplicationTests/` are pure SwiftPM test targets with **no** Apple framework imports beyond `Foundation` and `XCTest`. They run in <1 s.

## 12. Build, sign, distribute

- Personal Apple Developer ID for code signing (already on the machine, presumed).
- App is sandboxed with `com.apple.security.app-sandbox = true` and `com.apple.security.device.audio-input = true`.
- `Info.plist` carries `NSAudioCaptureUsageDescription = "<app> needs to listen to what other apps are playing in order to draw visualizations of it."`.
- v1 ships as a local `.app` you can drag to /Applications. No notarization for v1; we add it later if we share with others.

## 13. Risks and mitigations

1. **Tap creation fails after sleep/wake** (known macOS 15 regression). Mitigation: on launch, sweep stale `Tap-*` private aggregate devices; on `tapCreationFailed`, retry once after a 500 ms delay before reporting.
2. **Target app stops emitting audio** → no IOProc callbacks at all (silence is "no callbacks", not "zero samples"). Mitigation: KVO `kAudioProcessPropertyIsRunningOutput` on the target process and surface "Waiting for audio" overlay; do not interpret silence as "tap broken".
3. **User switches default output mid-session** invalidates the aggregate. Mitigation: listen for `kAudioHardwarePropertyDefaultSystemOutputDevice` changes and rebuild aggregate + IOProc without dropping the user's scene/palette.
4. **Format changes mid-stream** (rare; happens when source app reconfigures). Mitigation: re-read `kAudioTapPropertyFormat` on each `kAudioDevicePropertyStreamFormat` change; resize ring buffer if channel count changes.
5. **Sandbox + private aggregate** is fine, but `kAudioAggregateDeviceIsPrivateKey: false` would fail under sandbox — make sure we always pass `true`.

## 14. Out of scope (deliberately)

- Recording / exporting audio or video.
- Per-app routing or volume control.
- Custom palette editor (v1 ships 3 presets, hard-coded).
- A scene plugin SDK.
- Beat detection beyond simple energy threshold (no BPM-locked effects).
- Multi-window or external-display mirroring beyond OS-level fullscreen.

## 15. Success criteria

- Launching the app on a clean macOS 14.2+ machine shows the permission gate; granting permission and starting playback in another app produces a visualization within 2 seconds.
- CPU usage during rendering stays under 8% on an M1 base.
- GPU frame time stays under 8 ms on an M1 base at 1440×900.
- All `DomainTests` and `ApplicationTests` pass; integration smoke script renders one off-screen Metal frame without errors in CI.
- Codebase has zero Apple-framework imports inside `Domain/` and `Application/`.
