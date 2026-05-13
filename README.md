# Audio Video Gen

A macOS visualizer that captures system audio output and renders Windows XP Media Player–style visualizations in Metal. Tap any app's audio or all system audio — no virtual audio device, no microphone, no setup beyond a one-time permission prompt.

![Bars / Scope / Alchemy](docs/screenshots/preview.png) <!-- placeholder; remove or replace later -->

## Highlights

- **Real-time system-audio capture** via Core Audio Taps (macOS 14.2+ API). No BlackHole or kernel extensions required.
- **Three visualizers**: Bars (spectrum analyzer), Scope (oscilloscope with additive glow), Alchemy (80 000-particle compute shader reacting to bass + beat detection).
- **Per-app or system-wide audio source** — pick "All system audio" or a specific running app (Spotify, Chrome, Music, …). The picker refreshes once per second.
- **Live language switching** (English + Spanish) via Xcode 15 String Catalog. No restart.
- **Clean Architecture + DDD** — pure-Swift Domain and Application layers (no Apple framework imports), Infrastructure adapters isolated behind ports.

## Requirements

- macOS 14.2 or newer (Core Audio Taps API)
- Apple Silicon or Intel
- First launch will prompt for "Audio Capture" permission once

## Install (pre-built)

Download the latest `.dmg` from the [Releases page](https://github.com/SCHsebastian/audio-video-gen/releases), open it, and drag **AudioVisualizer.app** into your Applications folder. On first launch macOS will ask for permission to listen to other apps' audio — accept it once and you're done.

> The binary is ad-hoc signed (not notarized). macOS Gatekeeper may show a warning on first run. Right-click → Open, or run `xattr -dr com.apple.quarantine /Applications/AudioVisualizer.app` once.

## Use

1. Launch the app — a window opens with a Metal canvas.
2. Play audio in any other app (Spotify, Chrome, Music, …).
3. Pick a scene from the toolbar (**Bars / Scope / Alchemy**).
4. Pick an audio source from the dropdown, or leave it on **All system audio**.
5. Open the ⚙️ settings sheet to switch language.

## Build from source

```bash
git clone https://github.com/SCHsebastian/audio-video-gen.git
cd audio-video-gen
brew install xcodegen           # one-time
xcodegen generate               # rebuild AudioVisualizer.xcodeproj from project.yml
xcodebuild -project AudioVisualizer.xcodeproj -scheme AudioVisualizer build
open ~/Library/Developer/Xcode/DerivedData/AudioVisualizer-*/Build/Products/Debug/AudioVisualizer.app
```

Pure-Swift Domain + Application tests run without Xcode:

```bash
swift test
```

## Architecture

This project is **Clean Architecture + DDD** for a small native app. Quick map:

```
Sources/Domain/       — pure Swift, only Foundation imports; value objects, errors, ports
Sources/Application/  — use cases (Start/Stop/SelectSource/ChangeScene/ChangeLanguage)
AudioVisualizer/
  Infrastructure/     — CoreAudio, Analysis (vDSP), Metal, Persistence, Localization, Logging
  Presentation/       — SwiftUI views + @Observable view models
  App/                — @main + CompositionRoot (the single wiring point)
```

Architectural invariant: `grep -rE 'import (CoreAudio|Metal|SwiftUI|AppKit|…)' Sources/Domain Sources/Application` returns nothing. Domain and Application stay framework-pure so their tests run in <1 s without macOS frameworks.

See [`CLAUDE.md`](CLAUDE.md) for the developer-facing architecture notes (bounded contexts, port/adapter table, non-obvious wiring rules) and `docs/superpowers/specs/` for the original design documents.

## Diagnostic logging

The app emits structured `os.log` under subsystem `dev.audiovideogen.AudioVisualizer`. Stream it live while reproducing any issue:

```bash
/usr/bin/log stream --predicate 'subsystem == "dev.audiovideogen.AudioVisualizer"' --info --style compact
```

Categories: `capture`, `analysis`, `render`, `vm`. The capture category emits per-second IOProc stats (`callbacks/s`, `frames/s`, `peakAmp`) that tell you immediately whether the audio pipeline is alive.

## License

MIT. Includes [TPCircularBuffer](https://github.com/michaeltyson/TPCircularBuffer) by Michael Tyson (BSD).
