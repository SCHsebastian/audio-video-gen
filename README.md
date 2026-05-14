# Audio Visualizer

A native macOS app that taps **system audio output** in real time and renders
Windows XP Media Player–style visualizations in Metal — and exports those same
visuals to a silent `.mp4` driven by any audio file you point it at. **Eleven
scenes**, **seven palettes**, **stereo-aware** analysis, bilingual UI
(EN/ES), no virtual audio device, no microphone, no kernel extension — just
one TCC permission prompt and you're seeing your music.

Built end-to-end with [Claude](https://www.anthropic.com/claude) by
[Sebastián Cardona Henao](https://github.com/SCHsebastian).

![Bars / Scope / Alchemy / Tunnel / Lissajous](docs/screenshots/preview.png) <!-- placeholder; replace once recorded -->

---

## Highlights

- **System audio capture, no third-party driver.** Uses [Core Audio Taps](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps)
  (the public macOS 14.2+ API). No BlackHole, no Soundflower, no kext.
- **Eleven scenes** rendered in [Metal](https://developer.apple.com/metal/):
  Bars, Scope, Alchemy (compute-shader particles), Tunnel (2D-trick + spiral
  twist), Lissajous (parametric + stereo goniometer + Rose curve), Radial,
  Rings, Synthwave (Outrun horizon — palette-driven sky / sun / mountains /
  retrowave grid), Spectrogram (scrolling history), Milkdrop, Kaleidoscope.
- **Stereo-aware analysis.** The capture IOProc preserves L / R channels;
  the analyzer publishes per-channel sub-band energies; Scope draws two
  trigger-synced traces with shared auto-gain; Lissajous renders a real
  mid/side goniometer; Bars grows L upward and R downward from the centre;
  Tunnel leans toward the heavier bass side; Synthwave's beat-driven palette
  pulse warms grid / sun / mountain rim lights on hits.
- **Split view.** Press `V` (or use the toolbar) to render any two scenes
  side-by-side, each picking from the same shared audio bus.
- **Seven palettes** (Synthwave, XP Neon, Aurora, Sunset, Inferno, Ocean,
  Mono) with live preview swatches, cycle (`P`), random (`⇧P`), and per-scene
  randomization (Space or click anywhere on the canvas).
- **Export to video file** — render any scene + palette to a silent `.mp4`
  driven by any audio file. Two entry points: an in-app **Export…** sheet
  with a background-task progress chip, or a headless **`audiovis-render`**
  CLI binary for batch / scripted renders. See [Export to video](#export-to-video).
- **Real-time DSP** using Apple's [Accelerate / vDSP](https://developer.apple.com/documentation/accelerate/vdsp)
  for spectrum analysis (64 log-spaced bands + spectral centroid + onset
  flux) and a small energy-based beat detector that emits inter-beat
  intervals and a smoothed BPM estimate.
- **Diagnostics HUD** (`⌘D`) showing live FPS, RMS, beat strength, scene,
  and palette so you can see exactly what the renderer is doing.
- **Snapshot to Desktop** (`⌘S`) — grabs the next-presented drawable as a
  sRGB PNG.
- **Configurable frame-rate cap** (30 / 60 / 90 / 120 / unlimited) so you
  can trade smoothness for battery on the go.
- **Bilingual UI** (English + Spanish) via [Xcode 15 String Catalogs](https://developer.apple.com/documentation/xcode/localizing-and-varying-text-with-a-string-catalog),
  switchable live without restart.
- **Clean Architecture + DDD** — pure-Swift Domain and Application layers
  (zero Apple-framework imports), Infrastructure adapters isolated behind
  ports. See [Architecture](#architecture).

## Requirements

- macOS **14.2** or newer ([`CATapDescription`](https://developer.apple.com/documentation/coreaudio/catapdescription)
  was introduced in 14.2)
- Apple Silicon or Intel
- One TCC permission prompt on first launch ("Audio Capture") — only required
  for the live visualizer; the offline export reads its audio from a file.

## Install (pre-built)

Download the latest `AudioVisualizer-<version>.dmg` from the
[Releases page](https://github.com/SCHsebastian/audio-video-gen/releases),
open it, and drag **AudioVisualizer.app** onto the **Applications** alias —
the installer window already shows the two side-by-side with an arrow.

> The binary is ad-hoc signed (not notarized). On first launch macOS Gatekeeper
> may complain. Right-click → Open, or run
> `xattr -dr com.apple.quarantine /Applications/AudioVisualizer.app` once.

### Building the installer yourself

```bash
./scripts/make-dmg.sh
# → dist/AudioVisualizer-<version>.dmg
```

The script does a Release build, stages it alongside a `/Applications`
symlink and the branded background, then uses AppleScript to set the Finder
window's icon positions and background image, and finally compresses the
result with `hdiutil convert -format UDZO`.

## Use

1. Launch the app — a Metal canvas window opens.
2. Play audio in any other app (Music, Spotify, Chrome, …).
3. Grant **Audio Capture** access the first time (one prompt, ever).
4. Drive it from the floating toolbar or these keyboard shortcuts:

| Shortcut | Action |
|----------|--------|
| `1`–`9`, `0`, `-` | Switch scene (Bars / Scope / Alchemy / Tunnel / Lissajous / Radial / Rings / Synthwave / Spectrogram / Milkdrop / Kaleidoscope) |
| `←` `→`  | Previous / next scene |
| `Space` or click | Randomize the current scene |
| `P` / `⇧P` | Cycle / randomize the color palette |
| `V`      | Toggle split view (two scenes side-by-side) |
| `⌘S`     | Save a PNG snapshot to the Desktop |
| `⌘D`     | Toggle the diagnostics HUD |
| `F` / `⌃⌘F` | Toggle fullscreen |
| `?`      | Open the About / Help sheet |

The **Settings** sheet (gear icon, four tabs):

- **General** — language, reduce motion, diagnostics HUD, reset to defaults.
- **Visuals** — palette swatch grid, default scene, animation speed, **FPS
  cap** (30 / 60 / 90 / 120 / unlimited), scene order + auto-shuffle timer.
- **Audio** — gain (boost visual response without changing playback volume)
  and beat sensitivity.
- **About** — author + Claude credits, full shortcut sheet, version.

## Export to video

The same scenes + palettes + analyzer + beat detector that drive the live
canvas also power an offline pipeline that renders any audio file to a silent
`.mp4`. The source audio is **not** embedded in the output — the deliverable
is video-only.

### From the app

Click the **Export…** button in the toolbar. The export sheet asks for:

- **Audio source** — any file the platform can decode (mp3, wav, m4a, aac,
  flac, aiff, caf).
- **Scene + palette** — independent of what the live preview shows.
- **Resolution** — 720p / 1080p / 4K.
- **Frame rate** — 30 / 60 fps.
- **Output** — `.mp4` save location, default `<audio-basename>.mp4`.

Hit **Start**. The sheet dismisses, a progress chip slides into the toolbar
with percent + a Cancel button, and the live visualizer keeps running. When
the encode finishes the chip shows **Done · Reveal** for ~3 s; click it to
open Finder on the file.

### From the command line

`audiovis-render` is a standalone binary that runs the same offline pipeline
without opening the app. It's not sandboxed so it can read / write any path.

```bash
# Build the CLI target (only needed once, or after pulling changes)
xcodegen generate
xcodebuild -project AudioVisualizer.xcodeproj -scheme audiovis-render \
           -destination 'platform=macOS' build

# Find it under DerivedData
BIN=$(ls ~/Library/Developer/Xcode/DerivedData/AudioVisualizer-*/Build/Products/Debug/audiovis-render | head -1)

# Render
"$BIN" song.mp3 out.mp4
"$BIN" song.wav out.mp4 --scene synthwave --resolution 1080p --fps 60
"$BIN" song.flac out.mp4 --scene tunnel --palette "Aurora" --resolution 4k --fps 30
"$BIN" --help
```

Options:

| Flag | Values | Default |
|------|--------|---------|
| `--scene` | `bars` `scope` `alchemy` `tunnel` `lissajous` `radial` `rings` `synthwave` `spectrogram` `milkdrop` `kaleidoscope` | `bars` |
| `--palette` | palette name (matches the in-app picker) | `Synthwave` |
| `--resolution` | `720p` `1080p` `4k` | `1080p` |
| `--fps` | `30` `60` | `60` |

Drop a symlink on `$PATH` if you want it project-wide:

```bash
ln -sf "$BIN" /usr/local/bin/audiovis-render
```

H.264 in `.mp4`, hardware-encoded via VideoToolbox, BT.709 colour. The encoder
runs in lock-step with a zero-copy IOSurface-backed `CVPixelBuffer` pool that
Metal binds directly as a render target — no read-back, no CPU memcpy in the
hot path.

## Build from source

```bash
git clone https://github.com/SCHsebastian/audio-video-gen.git
cd audio-video-gen

# Domain + Application tests (pure Swift, <1 s, no Xcode required)
swift test

# Whole app (uses XcodeGen to regenerate the .xcodeproj from project.yml)
brew install xcodegen
xcodegen generate

# Live visualizer app
xcodebuild -project AudioVisualizer.xcodeproj -scheme AudioVisualizer \
           -destination 'platform=macOS' build
open ~/Library/Developer/Xcode/DerivedData/AudioVisualizer-*/Build/Products/Debug/AudioVisualizer.app

# Offline render CLI
xcodebuild -project AudioVisualizer.xcodeproj -scheme audiovis-render \
           -destination 'platform=macOS' build
```

Regenerate the Xcode project (`xcodegen generate`) any time you add or move a
source file under `AudioVisualizer/` or `cli/`, change `project.yml`, or
modify `Package.swift`.

## Architecture

Clean Architecture, lightly DDD-flavored:

```
Sources/Domain/        — pure Swift, only Foundation imports
                         value objects, errors, ports (protocols)
  AudioAnalysis/         SpectrumFrame, BeatEvent, WaveformBuffer
  AudioCapture/          AudioSource, capture port
  Export/                AudioFileDecoding + OfflineVideoRendering ports,
                         RenderOptions, ExportError
  Visualization/         SceneKind, ColorPalette, rendering port
  Localization/          L10nKey, language VO, localizer port
  Preferences/           UserPreferences VO, preferences port
Sources/Application/   — use cases (Start, Stop, SelectSource, ChangeScene,
                         ChangeLanguage, ExportVisualization)
AudioVisualizer/
  Infrastructure/      — Apple framework adapters
    CoreAudio/           Core Audio Taps capture + TCC permission
    Analysis/            vDSP spectrum analyzer + energy beat detector
    Metal/               renderer + 11 scenes + 7 palettes
    Export/              AVAssetReader-backed file decoder +
                         AVAssetWriter-backed offline renderer
    Persistence/         UserDefaults-backed preferences
    Localization/        Xcode String Catalog → @Observable localizer
    Logging/             os.log subsystems
  Presentation/        — SwiftUI views + @Observable view models
                         (live canvas + Export sheet + progress chip)
  App/                 — @main entry point + CompositionRoot
cli/                   — audiovis-render @main entry point (CLI tool target)
Vendor/TPCircularBuffer/ — BSD lock-free ring buffer (C)
```

Both the in-app Export sheet and the `audiovis-render` CLI compose the same
Domain + Application code, and the offline renderer shares its
`MTLDevice` / `MTLCommandQueue` / `MTLLibrary` with the live renderer via the
existing `makeSecondary`-style factory pattern.

The **architectural invariant** is enforced by reading code, not tooling:

```bash
grep -rE 'import (CoreAudio|AVFoundation|Metal|MetalKit|Accelerate|SwiftUI|AppKit)' \
      Sources/Domain Sources/Application
```

…must return zero matches. Domain and Application stay framework-pure so the
test suite for them runs in <1 second without macOS frameworks. The
[CompositionRoot](AudioVisualizer/App/CompositionRoot.swift) is the only place
that constructs concrete adapters and hands them to use cases.

See [`CLAUDE.md`](CLAUDE.md) for the developer-facing architecture notes
(bounded contexts, port/adapter table, the non-obvious wiring rules around
the IOProc thread and per-app capture), and `docs/superpowers/specs/` for the
original design specs (including [`2026-05-14-offline-render-pipeline-design.md`](docs/superpowers/specs/2026-05-14-offline-render-pipeline-design.md)
for the export feature).

## How it works (90-second tour)

1. **Capture.** [`CoreAudioTapCapture`](AudioVisualizer/Infrastructure/CoreAudio/CoreAudioTapCapture.swift)
   creates a `CATapDescription` for the default output device, builds a
   private aggregate device around it, and registers an `AudioDeviceIOProc`
   that the OS calls on its dedicated IO thread (≈ every 5 ms).
2. **RT-safe ring.** The IOProc writes interleaved L / R Float32 pairs
   (`SIMD2<Float>`, documented stride 8) into a [TPCircularBuffer](https://github.com/michaeltyson/TPCircularBuffer)
   — a lock-free single-producer/single-consumer ring buffer. The IOProc never
   allocates, never touches the Swift runtime, never takes a lock.
3. **Drain.** A user-interactive drain queue pulls 1024-frame chunks out of
   the ring buffer and yields them down an `AsyncStream<AudioFrame>` carrying
   the mono mixdown + the L / R channels.
4. **DSP.** Each frame is fed to [`VDSPSpectrumAnalyzer`](AudioVisualizer/Infrastructure/Analysis/VDSPSpectrumAnalyzer.swift)
   (Hann window → real FFT → magnitudes → 64 log-spaced bands, plus log-Hz
   spectral centroid + positive spectral flux; two extra per-channel FFTs
   produce `leftBands` / `rightBands` when the source is stereo) and to
   [`EnergyBeatDetector`](AudioVisualizer/Infrastructure/Analysis/EnergyBeatDetector.swift)
   (short-window energy vs. running average, plus mach-timebase derived
   inter-beat interval + EMA-smoothed BPM).
5. **Render.** Results are handed to
   [`MetalVisualizationRenderer`](AudioVisualizer/Infrastructure/Metal/MetalVisualizationRenderer.swift),
   which **lazily materializes** the active scene's pipelines on first
   navigation and releases the previous scene on switch. Each frame, the
   chosen scene encodes a [Metal](https://developer.apple.com/metal/) draw
   pass against a 256-pixel 1-D LUT palette texture.
6. **Export (parallel pipeline).** Same analyzer + beat detector wired to
   [`AVAudioFileDecoder`](AudioVisualizer/Infrastructure/Export/AVAudioFileDecoder.swift)
   (AVAssetReader → 48 kHz Float32 interleaved stereo → the same 1024-frame
   `AudioFrame` contract the live capture publishes) and to
   [`AVOfflineVideoRenderer`](AudioVisualizer/Infrastructure/Export/AVOfflineVideoRenderer.swift)
   (offscreen render to an IOSurface-backed `CVPixelBuffer` bound as an
   `MTLTexture` via `CVMetalTextureCache`; H.264 encode via VideoToolbox).

## Diagnostic logging

The app emits structured `os.log` under subsystem
`dev.audiovideogen.AudioVisualizer`. Stream it live while reproducing any
issue:

```bash
# Note: zsh has a `log` builtin. Use the absolute path.
/usr/bin/log stream --predicate 'subsystem == "dev.audiovideogen.AudioVisualizer"' \
                    --info --style compact
```

Categories: `capture`, `analysis`, `render`, `vm`.

- The **capture** category emits per-second IOProc stats
  (`callbacks/s`, `frames/s`, `peakAmp`). Non-zero `peakAmp` means
  non-silent audio is reaching the ring buffer.
- The **render** category logs scene materialization & release
  (`scene materialized: tunnel`, `scene released: bars`) plus per-second
  `consume` framerate.
- The **vm** category logs state transitions and snapshot results.

`audiovis-render` prints percent-progress to stdout and errors to stderr; it
does not emit `os.log` messages.

## Testing

```bash
swift test                                              # Domain + Application
swift test --filter DomainTests.LanguageTests           # single class
xcodebuild test -project AudioVisualizer.xcodeproj \
                -scheme AudioVisualizer \
                -destination 'platform=macOS'           # full Xcode suite
```

The Xcode test suite includes the offline-render infrastructure tests, which
encode a real silent 720p30 `.mp4` via the actual Metal device and read it
back through `AVURLAsset` to verify dimensions / duration / no audio track.

## Credits

- **Built by [Sebastián Cardona Henao](https://github.com/SCHsebastian)**
  with [Claude](https://www.anthropic.com/claude) (Anthropic), pair-programmed
  end-to-end.
- Inspired by the Windows XP Media Player visualizations of a bygone era.
- Vendored [TPCircularBuffer](https://github.com/michaeltyson/TPCircularBuffer)
  by Michael Tyson (BSD 2-Clause).

## License

MIT — see [`LICENSE`](LICENSE). Free to use, fork, modify, ship in your own
products, commercial or otherwise. A copyright notice in derivative work is
appreciated.
