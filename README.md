# Audio Visualizer

A native macOS app that taps **system audio output** in real time and renders
Windows XP Media Player–style visualizations in Metal. Five scenes, six
palettes, bilingual UI (EN/ES), no virtual audio device, no microphone, no
kernel extension — just one TCC permission prompt and you're seeing your
music.

Built end-to-end with [Claude](https://www.anthropic.com/claude) by
[Sebastián Cardona Henao](https://github.com/SCHsebastian).

![Bars / Scope / Alchemy / Tunnel / Lissajous](docs/screenshots/preview.png) <!-- placeholder; replace once recorded -->

---

## Highlights

- **System audio capture, no third-party driver.** Uses [Core Audio Taps](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps)
  (the public macOS 14.2+ API). No BlackHole, no Soundflower, no kext.
- **Five scenes** rendered in [Metal](https://developer.apple.com/metal/):
  Bars (spectrum), Scope (oscilloscope), Alchemy (80 000-particle compute
  shader), Tunnel (raymarched), Lissajous (XY parametric).
- **Six color palettes** with live preview swatches, cycle (P), random (⇧P),
  and per-scene randomization (Space or click anywhere on the canvas).
- **Real-time DSP** using Apple's [Accelerate / vDSP](https://developer.apple.com/documentation/accelerate/vdsp)
  for spectrum analysis and a small energy-based beat detector that drives
  ambient flashes.
- **Diagnostics HUD** (⌘D) showing live FPS, RMS, beat strength, scene, and
  palette so you can see exactly what the renderer is doing.
- **Snapshot to Desktop** (⌘S) — grabs the next-presented drawable as a sRGB
  PNG.
- **Configurable frame-rate cap** (30 / 60 / 90 / 120 / unlimited) so you can
  trade smoothness for battery on the go.
- **Bilingual UI** (English + Spanish) via [Xcode 15 String Catalogs](https://developer.apple.com/documentation/xcode/localizing-and-varying-text-with-a-string-catalog),
  switchable live without restart.
- **Clean Architecture + DDD** — pure-Swift Domain and Application layers
  (zero Apple-framework imports), Infrastructure adapters isolated behind
  ports. See [Architecture](#architecture).

## Requirements

- macOS **14.2** or newer ([`CATapDescription`](https://developer.apple.com/documentation/coreaudio/catapdescription)
  was introduced in 14.2)
- Apple Silicon or Intel
- One TCC permission prompt on first launch ("Audio Capture")

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
| `1`–`5`  | Switch scene (Bars / Scope / Alchemy / Tunnel / Lissajous) |
| `←` `→`  | Previous / next scene |
| `Space` or click | Randomize the current scene |
| `P` / `⇧P` | Cycle / randomize the color palette |
| `⌘S`     | Save a PNG snapshot to the Desktop |
| `⌘D`     | Toggle the diagnostics HUD |
| `F` / `⌃⌘F` | Toggle fullscreen |
| `?`      | Open the About / Help sheet |

The **Settings** sheet (gear icon, four tabs):

- **General** — language, reduce motion, diagnostics HUD, reset to defaults.
- **Visuals** — palette swatch grid, default scene, animation speed, **FPS
  cap** (30 / 60 / 90 / 120 / unlimited).
- **Audio** — gain (boost visual response without changing playback volume)
  and beat sensitivity.
- **About** — author + Claude credits, full shortcut sheet, version.

## Build from source

```bash
git clone https://github.com/SCHsebastian/audio-video-gen.git
cd audio-video-gen

# Domain + Application tests (pure Swift, <1 s, no Xcode required)
swift test

# Whole app (uses XcodeGen to regenerate the .xcodeproj from project.yml)
brew install xcodegen
xcodegen generate
xcodebuild -project AudioVisualizer.xcodeproj -scheme AudioVisualizer \
           -destination 'platform=macOS' build

open ~/Library/Developer/Xcode/DerivedData/AudioVisualizer-*/Build/Products/Debug/AudioVisualizer.app
```

Regenerate the Xcode project (`xcodegen generate`) any time you add or move a
source file under `AudioVisualizer/`, change `project.yml`, or modify
`Package.swift`.

## Architecture

Clean Architecture, lightly DDD-flavored:

```
Sources/Domain/        — pure Swift, only Foundation imports
                         value objects, errors, ports (protocols)
Sources/Application/   — use cases (Start, Stop, SelectSource, ChangeScene,
                         ChangeLanguage)
AudioVisualizer/
  Infrastructure/      — Apple framework adapters
    CoreAudio/           Core Audio Taps capture + TCC permission
    Analysis/            vDSP spectrum analyzer + energy beat detector
    Metal/               renderer + 5 scenes + 6 palettes
    Persistence/         UserDefaults-backed preferences
    Localization/        Xcode String Catalog → @Observable localizer
    Logging/             os.log subsystems
  Presentation/        — SwiftUI views + @Observable view models
  App/                 — @main entry point + CompositionRoot
Vendor/TPCircularBuffer/ — BSD lock-free ring buffer (C)
```

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
original design specs.

## How it works (90-second tour)

1. **Capture.** [`CoreAudioTapCapture`](AudioVisualizer/Infrastructure/CoreAudio/CoreAudioTapCapture.swift)
   creates a `CATapDescription` for the default output device, builds a
   private aggregate device around it, and registers an `AudioDeviceIOProc`
   that the OS calls on its dedicated IO thread (≈ every 5 ms).
2. **RT-safe ring.** The IOProc downmixes the (interleaved or
   non-interleaved) Float32 audio to mono and writes it into a
   [TPCircularBuffer](https://github.com/michaeltyson/TPCircularBuffer)
   — a lock-free single-producer/single-consumer ring buffer. The IOProc never
   allocates, never touches the Swift runtime, never takes a lock.
3. **Drain.** A user-interactive drain queue pulls 1024-sample mono frames
   out of the ring buffer and yields them down an `AsyncStream`.
4. **DSP.** Each frame is fed to [`VDSPSpectrumAnalyzer`](AudioVisualizer/Infrastructure/Analysis/VDSPSpectrumAnalyzer.swift)
   (Hann window → real FFT → magnitudes → 64 log-spaced bands) and to
   [`EnergyBeatDetector`](AudioVisualizer/Infrastructure/Analysis/EnergyBeatDetector.swift)
   (short-window energy vs. running average).
5. **Render.** Results are handed to
   [`MetalVisualizationRenderer`](AudioVisualizer/Infrastructure/Metal/MetalVisualizationRenderer.swift),
   which **lazily materializes** the active scene's pipelines on first
   navigation and releases the previous scene on switch. Each frame, the
   chosen scene encodes a [Metal](https://developer.apple.com/metal/) draw
   pass against a 256-pixel 1-D LUT palette texture.

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

## Testing

```bash
swift test                                              # Domain + Application
swift test --filter DomainTests.LanguageTests           # single class
xcodebuild test -project AudioVisualizer.xcodeproj \
                -scheme AudioVisualizer \
                -destination 'platform=macOS'           # full Xcode suite
```

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
