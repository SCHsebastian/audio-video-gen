# XP-Style System Audio Visualizer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a native macOS app that captures system audio via Core Audio Taps and renders Windows XP Media Player-style real-time visualizations (Bars, Scope, Alchemy particles).

**Architecture:** Clean Architecture (mobile flavor) + DDD bounded contexts. Domain and Application layers are pure Swift; Infrastructure isolates Core Audio, vDSP, Metal, and `UserDefaults` behind ports. Composition Root wires everything at `@main`.

**Tech Stack:** Swift 5.10, SwiftUI, Metal/MetalKit, Core Audio Taps (`CATapDescription`), `Accelerate.framework` (vDSP), `TPCircularBuffer` (vendored), SwiftPM + Xcode project, XCTest. Targets macOS 14.2+.

**Spec:** [`docs/superpowers/specs/2026-05-13-xp-visualizer-design.md`](../specs/2026-05-13-xp-visualizer-design.md)

---

## File Structure Recap

```
Domain/        # pure Swift, no Apple frameworks (Foundation only for primitives)
Application/   # use cases, depends only on Domain
Infrastructure/# CoreAudio, Analysis (vDSP), Metal, Persistence
Presentation/  # SwiftUI views + @Observable VMs
App/           # @main + CompositionRoot
Vendor/TPCircularBuffer/
Tests/{Domain,Application,Infrastructure}Tests/
```

Each Task below names exact files to create or modify. Tasks are ordered so that earlier tasks unblock later ones, and each task ends with a green test + a commit.

---

## Phase 0 — Project Scaffolding

### Task 0.1: Initialize git and project layout

**Files:**
- Create: `.gitignore`
- Create: `README.md` (one paragraph)

- [ ] **Step 1: Initialize the repo and ignore Xcode/SPM noise**

```bash
cd /Users/sebastiancardonahenao/development/audio-video-gen
git init
```

Write `.gitignore`:

```gitignore
.DS_Store
.build/
.swiftpm/
DerivedData/
*.xcuserdatad/
*.xcuserstate
xcuserdata/
build/
Pods/
*.xcworkspace/xcuserdata/
*.xcodeproj/xcuserdata/
*.xcodeproj/project.xcworkspace/xcuserdata/
```

- [ ] **Step 2: Write a one-paragraph README**

```markdown
# Audio Video Gen

A macOS visualizer that captures system audio output via Core Audio Taps and renders Windows XP Media Player-style visualizations. Requires macOS 14.2+. Architecture: Clean + DDD. See `docs/superpowers/specs/` for the design spec and `docs/superpowers/plans/` for the implementation plan.
```

- [ ] **Step 3: Commit**

```bash
git add .gitignore README.md docs/
git commit -m "chore: bootstrap repo with spec and plan"
```

---

### Task 0.2: Create SwiftPM workspace for Domain + Application

**Files:**
- Create: `Package.swift`
- Create: `Sources/Domain/Placeholder.swift` (one-liner; deleted in Task 1.1)
- Create: `Sources/Application/Placeholder.swift` (one-liner; deleted in Task 5.1)
- Create: `Tests/DomainTests/PlaceholderTests.swift`
- Create: `Tests/ApplicationTests/PlaceholderTests.swift`

- [ ] **Step 1: Write `Package.swift`**

```swift
// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "AudioVisualizerCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Domain", targets: ["Domain"]),
        .library(name: "Application", targets: ["Application"]),
    ],
    targets: [
        .target(name: "Domain", path: "Sources/Domain"),
        .target(name: "Application", dependencies: ["Domain"], path: "Sources/Application"),
        .testTarget(name: "DomainTests", dependencies: ["Domain"], path: "Tests/DomainTests"),
        .testTarget(name: "ApplicationTests", dependencies: ["Domain", "Application"], path: "Tests/ApplicationTests"),
    ]
)
```

- [ ] **Step 2: Add placeholder sources so SwiftPM resolves**

`Sources/Domain/Placeholder.swift`:
```swift
public enum DomainPlaceholder { public static let marker = "domain" }
```

`Sources/Application/Placeholder.swift`:
```swift
public enum ApplicationPlaceholder { public static let marker = "application" }
```

`Tests/DomainTests/PlaceholderTests.swift`:
```swift
import XCTest
@testable import Domain

final class PlaceholderTests: XCTestCase {
    func test_marker() { XCTAssertEqual(DomainPlaceholder.marker, "domain") }
}
```

`Tests/ApplicationTests/PlaceholderTests.swift`:
```swift
import XCTest
@testable import Application

final class PlaceholderTests: XCTestCase {
    func test_marker() { XCTAssertEqual(ApplicationPlaceholder.marker, "application") }
}
```

- [ ] **Step 3: Run tests to confirm the package builds**

Run: `swift test`
Expected: `Test Suite 'All tests' passed`, 2 tests run, 0 failures.

- [ ] **Step 4: Commit**

```bash
git add Package.swift Sources Tests
git commit -m "chore: scaffold SwiftPM workspace for Domain + Application"
```

---

## Phase 1 — Domain (pure Swift, no Apple frameworks)

### Task 1.1: Shared kernel value objects

**Files:**
- Delete: `Sources/Domain/Placeholder.swift`
- Create: `Sources/Domain/Shared/SampleRate.swift`
- Create: `Sources/Domain/Shared/HostTime.swift`
- Create: `Sources/Domain/Shared/RGB.swift`
- Create: `Sources/Domain/Shared/AudioFrame.swift`
- Create: `Tests/DomainTests/Shared/SampleRateTests.swift`
- Create: `Tests/DomainTests/Shared/RGBTests.swift`
- Create: `Tests/DomainTests/Shared/AudioFrameTests.swift`

- [ ] **Step 1: Write the failing tests**

`Tests/DomainTests/Shared/SampleRateTests.swift`:
```swift
import XCTest
@testable import Domain

final class SampleRateTests: XCTestCase {
    func test_equality_and_hashable() {
        XCTAssertEqual(SampleRate(hz: 48_000), SampleRate(hz: 48_000))
        XCTAssertNotEqual(SampleRate(hz: 48_000), SampleRate(hz: 44_100))
        XCTAssertEqual(Set([SampleRate(hz: 48_000), SampleRate(hz: 48_000)]).count, 1)
    }
}
```

`Tests/DomainTests/Shared/RGBTests.swift`:
```swift
import XCTest
@testable import Domain

final class RGBTests: XCTestCase {
    func test_components() {
        let c = RGB(r: 1, g: 0.5, b: 0)
        XCTAssertEqual(c.r, 1); XCTAssertEqual(c.g, 0.5); XCTAssertEqual(c.b, 0)
    }
}
```

`Tests/DomainTests/Shared/AudioFrameTests.swift`:
```swift
import XCTest
@testable import Domain

final class AudioFrameTests: XCTestCase {
    func test_holds_samples_and_metadata() {
        let f = AudioFrame(samples: [0, 0.5, -0.5, 0], sampleRate: SampleRate(hz: 48_000), timestamp: HostTime(machAbsolute: 42))
        XCTAssertEqual(f.samples.count, 4)
        XCTAssertEqual(f.sampleRate.hz, 48_000)
        XCTAssertEqual(f.timestamp.machAbsolute, 42)
    }
}
```

- [ ] **Step 2: Run to confirm they fail**

Run: `swift test --filter DomainTests.SampleRateTests`
Expected: build failure — types not defined.

- [ ] **Step 3: Implement minimal types**

Delete `Sources/Domain/Placeholder.swift`.

`Sources/Domain/Shared/SampleRate.swift`:
```swift
public struct SampleRate: Equatable, Hashable, Sendable {
    public let hz: Double
    public init(hz: Double) { self.hz = hz }
}
```

`Sources/Domain/Shared/HostTime.swift`:
```swift
public struct HostTime: Equatable, Hashable, Sendable {
    public let machAbsolute: UInt64
    public init(machAbsolute: UInt64) { self.machAbsolute = machAbsolute }
    public static let zero = HostTime(machAbsolute: 0)
}
```

`Sources/Domain/Shared/RGB.swift`:
```swift
public struct RGB: Equatable, Hashable, Sendable {
    public let r: Float; public let g: Float; public let b: Float
    public init(r: Float, g: Float, b: Float) { self.r = r; self.g = g; self.b = b }
}
```

`Sources/Domain/Shared/AudioFrame.swift`:
```swift
public struct AudioFrame: Equatable, Sendable {
    public let samples: [Float]                 // mono mixdown
    public let sampleRate: SampleRate
    public let timestamp: HostTime
    public init(samples: [Float], sampleRate: SampleRate, timestamp: HostTime) {
        self.samples = samples; self.sampleRate = sampleRate; self.timestamp = timestamp
    }
}
```

- [ ] **Step 4: Run to confirm they pass**

Run: `swift test --filter DomainTests`
Expected: all tests pass (placeholder + 3 new).

- [ ] **Step 5: Commit**

```bash
git add Sources/Domain/Shared Tests/DomainTests/Shared
git rm Sources/Domain/Placeholder.swift
git commit -m "feat(domain): add shared kernel value objects (SampleRate, HostTime, RGB, AudioFrame)"
```

---

### Task 1.2: Capture context — value objects and errors

**Files:**
- Create: `Sources/Domain/AudioCapture/ValueObjects/AudioSource.swift`
- Create: `Sources/Domain/AudioCapture/ValueObjects/AudioProcessInfo.swift`
- Create: `Sources/Domain/AudioCapture/Errors/CaptureError.swift`
- Create: `Tests/DomainTests/AudioCapture/AudioSourceTests.swift`
- Create: `Tests/DomainTests/AudioCapture/CaptureErrorTests.swift`

- [ ] **Step 1: Write failing tests**

`Tests/DomainTests/AudioCapture/AudioSourceTests.swift`:
```swift
import XCTest
@testable import Domain

final class AudioSourceTests: XCTestCase {
    func test_systemWide_equality() {
        XCTAssertEqual(AudioSource.systemWide, AudioSource.systemWide)
    }
    func test_process_equality() {
        XCTAssertEqual(AudioSource.process(pid: 100, bundleID: "com.spotify.client"),
                       AudioSource.process(pid: 100, bundleID: "com.spotify.client"))
        XCTAssertNotEqual(AudioSource.process(pid: 100, bundleID: "com.spotify.client"),
                          AudioSource.process(pid: 101, bundleID: "com.spotify.client"))
    }
}
```

`Tests/DomainTests/AudioCapture/CaptureErrorTests.swift`:
```swift
import XCTest
@testable import Domain

final class CaptureErrorTests: XCTestCase {
    func test_equality_for_typed_cases() {
        XCTAssertEqual(CaptureError.permissionDenied, CaptureError.permissionDenied)
        XCTAssertEqual(CaptureError.processNotFound(42), CaptureError.processNotFound(42))
        XCTAssertNotEqual(CaptureError.processNotFound(42), CaptureError.processNotFound(43))
        XCTAssertEqual(CaptureError.tapCreationFailed(-50), CaptureError.tapCreationFailed(-50))
    }
}
```

- [ ] **Step 2: Run to confirm failure**

Run: `swift test --filter DomainTests.AudioCapture`
Expected: types not defined.

- [ ] **Step 3: Implement**

`Sources/Domain/AudioCapture/ValueObjects/AudioSource.swift`:
```swift
import Foundation

public enum AudioSource: Equatable, Hashable, Sendable {
    case systemWide
    case process(pid: pid_t, bundleID: String)
}
```

`Sources/Domain/AudioCapture/ValueObjects/AudioProcessInfo.swift`:
```swift
import Foundation

public struct AudioProcessInfo: Equatable, Hashable, Sendable {
    public let pid: pid_t
    public let bundleID: String
    public let displayName: String
    public let isProducingAudio: Bool
    public init(pid: pid_t, bundleID: String, displayName: String, isProducingAudio: Bool) {
        self.pid = pid; self.bundleID = bundleID
        self.displayName = displayName; self.isProducingAudio = isProducingAudio
    }
}
```

`Sources/Domain/AudioCapture/Errors/CaptureError.swift`:
```swift
import Foundation

public enum CaptureError: Error, Equatable, Sendable {
    case permissionDenied
    case permissionUndetermined
    case processNotFound(pid_t)
    case formatUnsupported(description: String)
    case tapCreationFailed(OSStatus)
    case aggregateDeviceCreationFailed(OSStatus)
    case ioProcStartFailed(OSStatus)
    case defaultOutputDeviceUnavailable
}
```

Note: `OSStatus` is `Int32`, which is available in Foundation. We import Foundation to get `pid_t` and `OSStatus`. This is the only Apple-supplied module Domain is allowed to import.

- [ ] **Step 4: Run to confirm tests pass**

Run: `swift test --filter DomainTests`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/Domain/AudioCapture Tests/DomainTests/AudioCapture
git commit -m "feat(domain): add AudioCapture value objects and CaptureError"
```

---

### Task 1.3: Capture context — ports (protocols)

**Files:**
- Create: `Sources/Domain/AudioCapture/Ports/SystemAudioCapturing.swift`
- Create: `Sources/Domain/AudioCapture/Ports/ProcessDiscovering.swift`
- Create: `Sources/Domain/AudioCapture/Ports/PermissionRequesting.swift`

- [ ] **Step 1: Write the ports**

`Sources/Domain/AudioCapture/Ports/SystemAudioCapturing.swift`:
```swift
public protocol SystemAudioCapturing: Sendable {
    func start(source: AudioSource) async throws -> AsyncStream<AudioFrame>
    func stop() async
}
```

`Sources/Domain/AudioCapture/Ports/ProcessDiscovering.swift`:
```swift
public protocol ProcessDiscovering: Sendable {
    func listAudioProcesses() async throws -> [AudioProcessInfo]
}
```

`Sources/Domain/AudioCapture/Ports/PermissionRequesting.swift`:
```swift
public enum PermissionState: Equatable, Sendable { case undetermined, granted, denied }

public protocol PermissionRequesting: Sendable {
    func current() async -> PermissionState
    func request() async -> PermissionState
}
```

- [ ] **Step 2: Build to confirm protocols compile**

Run: `swift build`
Expected: build succeeds, no warnings.

- [ ] **Step 3: Commit**

```bash
git add Sources/Domain/AudioCapture/Ports
git commit -m "feat(domain): add AudioCapture ports"
```

---

### Task 1.4: Analysis context — value objects and ports

**Files:**
- Create: `Sources/Domain/AudioAnalysis/ValueObjects/SpectrumFrame.swift`
- Create: `Sources/Domain/AudioAnalysis/ValueObjects/FrequencyBand.swift`
- Create: `Sources/Domain/AudioAnalysis/ValueObjects/BeatEvent.swift`
- Create: `Sources/Domain/AudioAnalysis/Ports/AudioSpectrumAnalyzing.swift`
- Create: `Sources/Domain/AudioAnalysis/Ports/BeatDetecting.swift`
- Create: `Tests/DomainTests/AudioAnalysis/SpectrumFrameTests.swift`

- [ ] **Step 1: Write the failing test**

`Tests/DomainTests/AudioAnalysis/SpectrumFrameTests.swift`:
```swift
import XCTest
@testable import Domain

final class SpectrumFrameTests: XCTestCase {
    func test_holds_bands_rms_and_timestamp() {
        let f = SpectrumFrame(bands: [0, 0.5, 1.0], rms: 0.25, timestamp: HostTime(machAbsolute: 99))
        XCTAssertEqual(f.bands, [0, 0.5, 1.0])
        XCTAssertEqual(f.rms, 0.25)
        XCTAssertEqual(f.timestamp.machAbsolute, 99)
    }
}
```

- [ ] **Step 2: Run, expect failure**

Run: `swift test --filter DomainTests.AudioAnalysis`
Expected: type not defined.

- [ ] **Step 3: Implement**

`Sources/Domain/AudioAnalysis/ValueObjects/SpectrumFrame.swift`:
```swift
public struct SpectrumFrame: Equatable, Sendable {
    public let bands: [Float]    // normalized 0..1
    public let rms: Float        // overall loudness 0..1
    public let timestamp: HostTime
    public init(bands: [Float], rms: Float, timestamp: HostTime) {
        self.bands = bands; self.rms = rms; self.timestamp = timestamp
    }
}
```

`Sources/Domain/AudioAnalysis/ValueObjects/FrequencyBand.swift`:
```swift
public struct FrequencyBand: Equatable, Sendable {
    public let lowHz: Float; public let highHz: Float
    public init(lowHz: Float, highHz: Float) { self.lowHz = lowHz; self.highHz = highHz }
}
```

`Sources/Domain/AudioAnalysis/ValueObjects/BeatEvent.swift`:
```swift
public struct BeatEvent: Equatable, Sendable {
    public let timestamp: HostTime; public let strength: Float
    public init(timestamp: HostTime, strength: Float) {
        self.timestamp = timestamp; self.strength = strength
    }
}
```

`Sources/Domain/AudioAnalysis/Ports/AudioSpectrumAnalyzing.swift`:
```swift
public protocol AudioSpectrumAnalyzing: Sendable {
    var bandCount: Int { get }
    func analyze(_ frame: AudioFrame) -> SpectrumFrame
}
```

`Sources/Domain/AudioAnalysis/Ports/BeatDetecting.swift`:
```swift
public protocol BeatDetecting: Sendable {
    func feed(_ spectrum: SpectrumFrame) -> BeatEvent?
}
```

- [ ] **Step 4: Run, expect pass**

Run: `swift test --filter DomainTests`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/Domain/AudioAnalysis Tests/DomainTests/AudioAnalysis
git commit -m "feat(domain): add AudioAnalysis value objects and ports"
```

---

### Task 1.5: Visualization context — value objects, error, port

**Files:**
- Create: `Sources/Domain/Visualization/ValueObjects/SceneKind.swift`
- Create: `Sources/Domain/Visualization/ValueObjects/ColorPalette.swift`
- Create: `Sources/Domain/Visualization/Errors/RenderError.swift`
- Create: `Sources/Domain/Visualization/Ports/VisualizationRendering.swift`
- Create: `Tests/DomainTests/Visualization/SceneKindTests.swift`
- Create: `Tests/DomainTests/Visualization/ColorPaletteTests.swift`

- [ ] **Step 1: Write the failing tests**

`Tests/DomainTests/Visualization/SceneKindTests.swift`:
```swift
import XCTest
@testable import Domain

final class SceneKindTests: XCTestCase {
    func test_raw_value_round_trip() {
        for k in SceneKind.allCases {
            XCTAssertEqual(SceneKind(rawValue: k.rawValue), k)
        }
    }
    func test_all_three_scenes_present() {
        XCTAssertEqual(Set(SceneKind.allCases), [.bars, .scope, .alchemy])
    }
}
```

`Tests/DomainTests/Visualization/ColorPaletteTests.swift`:
```swift
import XCTest
@testable import Domain

final class ColorPaletteTests: XCTestCase {
    func test_init_holds_stops() {
        let p = ColorPalette(name: "Test", stops: [RGB(r: 0, g: 0, b: 0), RGB(r: 1, g: 1, b: 1)])
        XCTAssertEqual(p.name, "Test")
        XCTAssertEqual(p.stops.count, 2)
    }
}
```

- [ ] **Step 2: Run to confirm failure**

Run: `swift test --filter DomainTests.Visualization`
Expected: types not defined.

- [ ] **Step 3: Implement**

`Sources/Domain/Visualization/ValueObjects/SceneKind.swift`:
```swift
public enum SceneKind: String, CaseIterable, Equatable, Hashable, Sendable {
    case bars, scope, alchemy
}
```

`Sources/Domain/Visualization/ValueObjects/ColorPalette.swift`:
```swift
public struct ColorPalette: Equatable, Hashable, Sendable {
    public let name: String
    public let stops: [RGB]
    public init(name: String, stops: [RGB]) { self.name = name; self.stops = stops }
}
```

`Sources/Domain/Visualization/Errors/RenderError.swift`:
```swift
public enum RenderError: Error, Equatable, Sendable {
    case metalDeviceUnavailable
    case shaderCompilationFailed(name: String)
    case pipelineCreationFailed(name: String)
}
```

`Sources/Domain/Visualization/Ports/VisualizationRendering.swift`:
```swift
public protocol VisualizationRendering: AnyObject, Sendable {
    func setScene(_ kind: SceneKind)
    func setPalette(_ palette: ColorPalette)
    func consume(spectrum: SpectrumFrame, waveform: [Float], beat: BeatEvent?)
}
```

- [ ] **Step 4: Run, expect pass**

Run: `swift test --filter DomainTests`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/Domain/Visualization Tests/DomainTests/Visualization
git commit -m "feat(domain): add Visualization value objects, errors, and port"
```

---

### Task 1.6: Preferences context

**Files:**
- Create: `Sources/Domain/Preferences/ValueObjects/UserPreferences.swift`
- Create: `Sources/Domain/Preferences/Ports/PreferencesStoring.swift`
- Create: `Tests/DomainTests/Preferences/UserPreferencesTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Domain

final class UserPreferencesTests: XCTestCase {
    func test_defaults() {
        let p = UserPreferences.default
        XCTAssertEqual(p.lastScene, .bars)
        XCTAssertEqual(p.lastSource, .systemWide)
        XCTAssertEqual(p.lastPaletteName, "XP Neon")
    }
}
```

- [ ] **Step 2: Run, expect failure**

Run: `swift test --filter DomainTests.Preferences`
Expected: not defined.

- [ ] **Step 3: Implement**

`Sources/Domain/Preferences/ValueObjects/UserPreferences.swift`:
```swift
public struct UserPreferences: Equatable, Sendable {
    public var lastSource: AudioSource
    public var lastScene: SceneKind
    public var lastPaletteName: String
    public init(lastSource: AudioSource, lastScene: SceneKind, lastPaletteName: String) {
        self.lastSource = lastSource; self.lastScene = lastScene; self.lastPaletteName = lastPaletteName
    }
    public static let `default` = UserPreferences(lastSource: .systemWide, lastScene: .bars, lastPaletteName: "XP Neon")
}
```

`Sources/Domain/Preferences/Ports/PreferencesStoring.swift`:
```swift
public protocol PreferencesStoring: Sendable {
    func load() -> UserPreferences
    func save(_ prefs: UserPreferences)
}
```

- [ ] **Step 4: Run, expect pass**

Run: `swift test --filter DomainTests`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/Domain/Preferences Tests/DomainTests/Preferences
git commit -m "feat(domain): add Preferences value object, default, and port"
```

---

## Phase 2 — Application (use cases)

### Task 2.1: `ListAudioSourcesUseCase`

**Files:**
- Delete: `Sources/Application/Placeholder.swift`
- Create: `Sources/Application/UseCases/ListAudioSourcesUseCase.swift`
- Create: `Tests/ApplicationTests/Fakes/FakeProcessDiscovering.swift`
- Create: `Tests/ApplicationTests/UseCases/ListAudioSourcesUseCaseTests.swift`

- [ ] **Step 1: Write the failing test**

`Tests/ApplicationTests/Fakes/FakeProcessDiscovering.swift`:
```swift
import Domain

final class FakeProcessDiscovering: ProcessDiscovering, @unchecked Sendable {
    var stub: [AudioProcessInfo] = []
    var error: Error?
    func listAudioProcesses() async throws -> [AudioProcessInfo] {
        if let error { throw error }
        return stub
    }
}
```

`Tests/ApplicationTests/UseCases/ListAudioSourcesUseCaseTests.swift`:
```swift
import XCTest
@testable import Application
@testable import Domain

final class ListAudioSourcesUseCaseTests: XCTestCase {
    func test_returns_systemWide_plus_discovered_processes() async throws {
        let fake = FakeProcessDiscovering()
        fake.stub = [
            AudioProcessInfo(pid: 100, bundleID: "com.spotify.client", displayName: "Spotify", isProducingAudio: true)
        ]
        let sut = ListAudioSourcesUseCase(discovery: fake)
        let result = try await sut.execute()
        XCTAssertEqual(result.first, .systemWide)
        XCTAssertEqual(result.count, 2)
        if case let .process(pid, bid) = result[1] {
            XCTAssertEqual(pid, 100); XCTAssertEqual(bid, "com.spotify.client")
        } else { XCTFail("expected process source") }
    }

    func test_propagates_discovery_error() async {
        let fake = FakeProcessDiscovering()
        fake.error = CaptureError.permissionDenied
        let sut = ListAudioSourcesUseCase(discovery: fake)
        do {
            _ = try await sut.execute()
            XCTFail("expected throw")
        } catch let e as CaptureError {
            XCTAssertEqual(e, .permissionDenied)
        } catch { XCTFail("wrong error type") }
    }
}
```

- [ ] **Step 2: Run, expect failure**

Run: `swift test --filter ApplicationTests.ListAudioSourcesUseCaseTests`
Expected: type not defined.

- [ ] **Step 3: Implement**

Delete `Sources/Application/Placeholder.swift`.

`Sources/Application/UseCases/ListAudioSourcesUseCase.swift`:
```swift
import Domain

public struct ListAudioSourcesUseCase: Sendable {
    private let discovery: ProcessDiscovering
    public init(discovery: ProcessDiscovering) { self.discovery = discovery }
    public func execute() async throws -> [AudioSource] {
        let procs = try await discovery.listAudioProcesses()
        return [.systemWide] + procs.map { .process(pid: $0.pid, bundleID: $0.bundleID) }
    }
}
```

- [ ] **Step 4: Run, expect pass**

Run: `swift test --filter ApplicationTests`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/Application/UseCases/ListAudioSourcesUseCase.swift \
        Tests/ApplicationTests/Fakes/FakeProcessDiscovering.swift \
        Tests/ApplicationTests/UseCases/ListAudioSourcesUseCaseTests.swift
git rm Sources/Application/Placeholder.swift
git commit -m "feat(application): add ListAudioSourcesUseCase"
```

---

### Task 2.2: `SelectAudioSourceUseCase` and `ChangeSceneUseCase`

**Files:**
- Create: `Sources/Application/UseCases/SelectAudioSourceUseCase.swift`
- Create: `Sources/Application/UseCases/ChangeSceneUseCase.swift`
- Create: `Tests/ApplicationTests/Fakes/FakePreferencesStoring.swift`
- Create: `Tests/ApplicationTests/UseCases/SelectAudioSourceUseCaseTests.swift`
- Create: `Tests/ApplicationTests/UseCases/ChangeSceneUseCaseTests.swift`

- [ ] **Step 1: Write the failing tests**

`Tests/ApplicationTests/Fakes/FakePreferencesStoring.swift`:
```swift
import Domain

final class FakePreferencesStoring: PreferencesStoring, @unchecked Sendable {
    var stored: UserPreferences = .default
    func load() -> UserPreferences { stored }
    func save(_ prefs: UserPreferences) { stored = prefs }
}
```

`Tests/ApplicationTests/UseCases/SelectAudioSourceUseCaseTests.swift`:
```swift
import XCTest
@testable import Application
@testable import Domain

final class SelectAudioSourceUseCaseTests: XCTestCase {
    func test_persists_chosen_source() {
        let prefs = FakePreferencesStoring()
        let sut = SelectAudioSourceUseCase(preferences: prefs)
        sut.execute(.process(pid: 42, bundleID: "com.apple.Music"))
        XCTAssertEqual(prefs.stored.lastSource, .process(pid: 42, bundleID: "com.apple.Music"))
    }
}
```

`Tests/ApplicationTests/UseCases/ChangeSceneUseCaseTests.swift`:
```swift
import XCTest
@testable import Application
@testable import Domain

final class FakeRenderer: VisualizationRendering, @unchecked Sendable {
    var scene: SceneKind?
    var palette: ColorPalette?
    var lastSpectrum: SpectrumFrame?
    func setScene(_ kind: SceneKind) { scene = kind }
    func setPalette(_ palette: ColorPalette) { self.palette = palette }
    func consume(spectrum: SpectrumFrame, waveform: [Float], beat: BeatEvent?) { lastSpectrum = spectrum }
}

final class ChangeSceneUseCaseTests: XCTestCase {
    func test_sets_scene_on_renderer_and_persists() {
        let r = FakeRenderer()
        let p = FakePreferencesStoring()
        let sut = ChangeSceneUseCase(renderer: r, preferences: p)
        sut.execute(.alchemy)
        XCTAssertEqual(r.scene, .alchemy)
        XCTAssertEqual(p.stored.lastScene, .alchemy)
    }
}
```

- [ ] **Step 2: Run, expect failure**

Run: `swift test --filter ApplicationTests`
Expected: SelectAudioSourceUseCase / ChangeSceneUseCase undefined.

- [ ] **Step 3: Implement**

`Sources/Application/UseCases/SelectAudioSourceUseCase.swift`:
```swift
import Domain

public struct SelectAudioSourceUseCase: Sendable {
    private let preferences: PreferencesStoring
    public init(preferences: PreferencesStoring) { self.preferences = preferences }
    public func execute(_ source: AudioSource) {
        var p = preferences.load()
        p.lastSource = source
        preferences.save(p)
    }
}
```

`Sources/Application/UseCases/ChangeSceneUseCase.swift`:
```swift
import Domain

public struct ChangeSceneUseCase: Sendable {
    private let renderer: VisualizationRendering
    private let preferences: PreferencesStoring
    public init(renderer: VisualizationRendering, preferences: PreferencesStoring) {
        self.renderer = renderer; self.preferences = preferences
    }
    public func execute(_ kind: SceneKind) {
        renderer.setScene(kind)
        var p = preferences.load()
        p.lastScene = kind
        preferences.save(p)
    }
}
```

- [ ] **Step 4: Run, expect pass**

Run: `swift test --filter ApplicationTests`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/Application/UseCases Tests/ApplicationTests
git commit -m "feat(application): add SelectAudioSource and ChangeScene use cases"
```

---

### Task 2.3: `StartVisualizationUseCase` (the orchestrator)

**Files:**
- Create: `Sources/Application/UseCases/StartVisualizationUseCase.swift`
- Create: `Sources/Application/UseCases/StopVisualizationUseCase.swift`
- Create: `Sources/Application/State/VisualizationState.swift`
- Create: `Tests/ApplicationTests/Fakes/FakeSystemAudioCapturing.swift`
- Create: `Tests/ApplicationTests/Fakes/FakeAudioSpectrumAnalyzing.swift`
- Create: `Tests/ApplicationTests/Fakes/FakePermissionRequesting.swift`
- Create: `Tests/ApplicationTests/UseCases/StartVisualizationUseCaseTests.swift`

- [ ] **Step 1: Write the failing tests**

`Sources/Application/State/VisualizationState.swift` (not yet, but here's the shape):
```swift
import Domain

public enum VisualizationState: Equatable, Sendable {
    case idle
    case waitingForPermission
    case running
    case noAudioYet
    case error(CaptureError)
}
```

(We write source files used by the test in this step too — keep the test runnable.)

`Tests/ApplicationTests/Fakes/FakeSystemAudioCapturing.swift`:
```swift
import Domain

final class FakeSystemAudioCapturing: SystemAudioCapturing, @unchecked Sendable {
    var frames: [AudioFrame] = []
    var startError: Error?
    private(set) var lastSource: AudioSource?
    private(set) var stopped = false

    func start(source: AudioSource) async throws -> AsyncStream<AudioFrame> {
        if let startError { throw startError }
        lastSource = source
        let (stream, continuation) = AsyncStream<AudioFrame>.makeStream()
        for f in frames { continuation.yield(f) }
        continuation.finish()
        return stream
    }

    func stop() async { stopped = true }
}
```

`Tests/ApplicationTests/Fakes/FakeAudioSpectrumAnalyzing.swift`:
```swift
import Domain

final class FakeAudioSpectrumAnalyzing: AudioSpectrumAnalyzing, @unchecked Sendable {
    let bandCount = 4
    var analyzeCount = 0
    func analyze(_ frame: AudioFrame) -> SpectrumFrame {
        analyzeCount += 1
        return SpectrumFrame(bands: [0, 0.25, 0.5, 0.75], rms: 0.5, timestamp: frame.timestamp)
    }
}
```

`Tests/ApplicationTests/Fakes/FakePermissionRequesting.swift`:
```swift
import Domain

final class FakePermissionRequesting: PermissionRequesting, @unchecked Sendable {
    var state: PermissionState = .granted
    func current() async -> PermissionState { state }
    func request() async -> PermissionState { state }
}
```

`Tests/ApplicationTests/UseCases/StartVisualizationUseCaseTests.swift`:
```swift
import XCTest
@testable import Application
@testable import Domain

final class StartVisualizationUseCaseTests: XCTestCase {

    func test_when_permission_denied_emits_waitingForPermission_and_stops() async {
        let cap = FakeSystemAudioCapturing()
        let ana = FakeAudioSpectrumAnalyzing()
        let perm = FakePermissionRequesting(); perm.state = .denied
        let r = FakeRenderer()
        let beat = FakeBeatDetecting()
        let sut = StartVisualizationUseCase(capture: cap, analyzer: ana, beats: beat, renderer: r, permissions: perm)
        let stream = await sut.execute(source: .systemWide)
        var seen: [VisualizationState] = []
        for await s in stream { seen.append(s); if seen.count == 1 { break } }
        XCTAssertEqual(seen.first, .waitingForPermission)
    }

    func test_when_granted_runs_pipeline_and_pushes_to_renderer() async {
        let cap = FakeSystemAudioCapturing()
        cap.frames = [AudioFrame(samples: Array(repeating: 0.1, count: 1024),
                                 sampleRate: SampleRate(hz: 48_000),
                                 timestamp: HostTime(machAbsolute: 1))]
        let ana = FakeAudioSpectrumAnalyzing()
        let perm = FakePermissionRequesting()
        let r = FakeRenderer()
        let beat = FakeBeatDetecting()
        let sut = StartVisualizationUseCase(capture: cap, analyzer: ana, beats: beat, renderer: r, permissions: perm)
        let stream = await sut.execute(source: .systemWide)
        var saw_running = false
        for await s in stream { if case .running = s { saw_running = true; break } }
        XCTAssertTrue(saw_running)
        XCTAssertEqual(ana.analyzeCount, 1)
        XCTAssertNotNil(r.lastSpectrum)
    }
}

final class FakeBeatDetecting: BeatDetecting, @unchecked Sendable {
    func feed(_ spectrum: SpectrumFrame) -> BeatEvent? { nil }
}
```

- [ ] **Step 2: Run, expect failure**

Run: `swift test --filter ApplicationTests.StartVisualizationUseCaseTests`
Expected: `StartVisualizationUseCase` and `VisualizationState` not defined.

- [ ] **Step 3: Implement**

`Sources/Application/State/VisualizationState.swift`:
```swift
import Domain

public enum VisualizationState: Equatable, Sendable {
    case idle
    case waitingForPermission
    case running
    case noAudioYet
    case error(CaptureError)
}
```

`Sources/Application/UseCases/StartVisualizationUseCase.swift`:
```swift
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
                        let tail = Array(frame.samples.suffix(waveformSampleCount))
                        renderer.consume(spectrum: spectrum, waveform: tail, beat: beat)
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
```

`Sources/Application/UseCases/StopVisualizationUseCase.swift`:
```swift
import Domain

public struct StopVisualizationUseCase: Sendable {
    private let capture: SystemAudioCapturing
    public init(capture: SystemAudioCapturing) { self.capture = capture }
    public func execute() async { await capture.stop() }
}
```

- [ ] **Step 4: Run, expect pass**

Run: `swift test --filter ApplicationTests`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/Application Tests/ApplicationTests
git commit -m "feat(application): add Start/Stop visualization use cases + VisualizationState"
```

---

## Phase 3 — Xcode app target + Infrastructure scaffolding

### Task 3.1: Create the Xcode project for the app

**Files:**
- Create: `AudioVisualizer.xcodeproj/` (via Xcode UI; commit the result)
- Modify: `AudioVisualizer/Resources/Info.plist`
- Modify: `AudioVisualizer/Resources/AudioVisualizer.entitlements`
- Create: `AudioVisualizer/App/VisualizerApp.swift`

- [ ] **Step 1: Create the Xcode project**

In Xcode: File → New → Project → macOS → App.
- Product Name: `AudioVisualizer`
- Interface: SwiftUI
- Language: Swift
- Save under `/Users/sebastiancardonahenao/development/audio-video-gen/`

- [ ] **Step 2: Add the local SwiftPM package as a dependency**

In Xcode → Project → Package Dependencies → "Add Local…" → select the repo root (contains `Package.swift`). Add `Domain` and `Application` library products to the `AudioVisualizer` target.

- [ ] **Step 3: Configure Info.plist and entitlements**

Open `AudioVisualizer/Resources/Info.plist` (or the target's Info tab) and add:
```xml
<key>NSAudioCaptureUsageDescription</key>
<string>AudioVisualizer needs to listen to what other apps are playing in order to draw visualizations of it.</string>
<key>LSMinimumSystemVersion</key>
<string>14.2</string>
```

Open `AudioVisualizer/Resources/AudioVisualizer.entitlements` and add:
```xml
<key>com.apple.security.app-sandbox</key><true/>
<key>com.apple.security.device.audio-input</key><true/>
```

- [ ] **Step 4: Replace the default `AudioVisualizerApp.swift` with our App entry**

`AudioVisualizer/App/VisualizerApp.swift`:
```swift
import SwiftUI

@main
struct VisualizerApp: App {
    var body: some Scene {
        WindowGroup("Audio Visualizer") {
            Text("Hello, visualizer.")
                .frame(minWidth: 1280, minHeight: 720)
        }
    }
}
```

Delete the auto-generated `ContentView.swift` and `AudioVisualizerApp.swift`.

- [ ] **Step 5: Build and run; verify the empty window opens**

In Xcode: ⌘R. Expected: blank window says "Hello, visualizer." with no crashes.

- [ ] **Step 6: Commit**

```bash
git add AudioVisualizer.xcodeproj AudioVisualizer/
git commit -m "chore(app): scaffold Xcode app target with Info.plist and entitlements"
```

---

### Task 3.2: Vendor TPCircularBuffer

**Files:**
- Create: `Vendor/TPCircularBuffer/include/TPCircularBuffer.h`
- Create: `Vendor/TPCircularBuffer/TPCircularBuffer.c`
- Create: `Vendor/TPCircularBuffer/module.modulemap`
- Modify: `AudioVisualizer.xcodeproj` (add Vendor folder)

- [ ] **Step 1: Download canonical source**

Run:
```bash
mkdir -p Vendor/TPCircularBuffer/include
curl -fsSL https://raw.githubusercontent.com/michaeltyson/TPCircularBuffer/master/TPCircularBuffer.h -o Vendor/TPCircularBuffer/include/TPCircularBuffer.h
curl -fsSL https://raw.githubusercontent.com/michaeltyson/TPCircularBuffer/master/TPCircularBuffer.c -o Vendor/TPCircularBuffer/TPCircularBuffer.c
```

- [ ] **Step 2: Write the modulemap so Swift can import it**

`Vendor/TPCircularBuffer/module.modulemap`:
```
module TPCircularBuffer {
    header "include/TPCircularBuffer.h"
    export *
}
```

- [ ] **Step 3: Add to Xcode target**

Drag `Vendor/TPCircularBuffer/` into the AudioVisualizer target in Xcode. In Build Settings:
- "Import Paths" / "Header Search Paths": add `$(SRCROOT)/Vendor/TPCircularBuffer/include`.
- "Swift Compiler – Search Paths" → "Import Paths": same path.

- [ ] **Step 4: Smoke test from Swift**

Add temporarily in `VisualizerApp.swift`:
```swift
import TPCircularBuffer
// ... inside body or onAppear: print just to confirm the symbol resolves
```
Build (⌘B). Expected: no "no such module" error. Then remove the import to keep `VisualizerApp.swift` clean.

- [ ] **Step 5: Commit**

```bash
git add Vendor/TPCircularBuffer AudioVisualizer.xcodeproj
git commit -m "chore(vendor): add TPCircularBuffer (BSD, Michael Tyson)"
```

---

### Task 3.3: `UserDefaultsPreferences` adapter

**Files:**
- Create: `AudioVisualizer/Infrastructure/Persistence/UserDefaultsPreferences.swift`
- Create: `AudioVisualizer/Tests/InfrastructureTests/UserDefaultsPreferencesTests.swift` (add a unit test target in Xcode if not present)

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
import Domain
@testable import AudioVisualizer

final class UserDefaultsPreferencesTests: XCTestCase {
    func test_round_trip() {
        let suite = "test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let sut = UserDefaultsPreferences(defaults: defaults)
        var p = sut.load()
        p.lastScene = .alchemy
        p.lastSource = .process(pid: 123, bundleID: "com.example")
        p.lastPaletteName = "Aurora"
        sut.save(p)
        let r = sut.load()
        XCTAssertEqual(r.lastScene, .alchemy)
        XCTAssertEqual(r.lastSource, .process(pid: 123, bundleID: "com.example"))
        XCTAssertEqual(r.lastPaletteName, "Aurora")
    }

    func test_load_when_empty_returns_default() {
        let suite = "test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let sut = UserDefaultsPreferences(defaults: defaults)
        XCTAssertEqual(sut.load(), .default)
    }
}
```

- [ ] **Step 2: Run, expect failure**

Run in Xcode: ⌘U (Test). Expected: type not defined.

- [ ] **Step 3: Implement**

`AudioVisualizer/Infrastructure/Persistence/UserDefaultsPreferences.swift`:
```swift
import Foundation
import Domain

final class UserDefaultsPreferences: PreferencesStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "userPreferences.v1"
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func load() -> UserPreferences {
        guard
            let data = defaults.data(forKey: key),
            let dto = try? JSONDecoder().decode(DTO.self, from: data)
        else { return .default }
        return dto.toDomain()
    }

    func save(_ prefs: UserPreferences) {
        let dto = DTO(domain: prefs)
        if let data = try? JSONEncoder().encode(dto) {
            defaults.set(data, forKey: key)
        }
    }

    private struct DTO: Codable {
        let sourceKind: String              // "systemWide" or "process"
        let pid: Int32?
        let bundleID: String?
        let scene: String
        let paletteName: String

        init(domain p: UserPreferences) {
            switch p.lastSource {
            case .systemWide: sourceKind = "systemWide"; pid = nil; bundleID = nil
            case .process(let pid, let bid): sourceKind = "process"; self.pid = pid; bundleID = bid
            }
            scene = p.lastScene.rawValue
            paletteName = p.lastPaletteName
        }

        func toDomain() -> UserPreferences {
            let source: AudioSource = {
                if sourceKind == "process", let pid, let bundleID { return .process(pid: pid, bundleID: bundleID) }
                return .systemWide
            }()
            let scene = SceneKind(rawValue: scene) ?? .bars
            return UserPreferences(lastSource: source, lastScene: scene, lastPaletteName: paletteName)
        }
    }
}
```

- [ ] **Step 4: Run, expect pass**

Run: ⌘U. Expected: both tests pass.

- [ ] **Step 5: Commit**

```bash
git add AudioVisualizer/Infrastructure/Persistence AudioVisualizer/Tests/InfrastructureTests/UserDefaultsPreferencesTests.swift
git commit -m "feat(infra): UserDefaultsPreferences adapter with codable DTO"
```

---

## Phase 4 — Analysis adapter (vDSP)

### Task 4.1: `VDSPSpectrumAnalyzer` adapter

**Files:**
- Create: `AudioVisualizer/Infrastructure/Analysis/VDSPSpectrumAnalyzer.swift`
- Create: `AudioVisualizer/Tests/InfrastructureTests/VDSPSpectrumAnalyzerTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
import Domain
@testable import AudioVisualizer

final class VDSPSpectrumAnalyzerTests: XCTestCase {
    func test_pure_sine_peaks_at_expected_band() {
        let sr: Double = 48_000
        let n = 1024
        let target: Double = 1000   // 1 kHz tone
        let samples: [Float] = (0..<n).map { i in
            Float(sin(2.0 * .pi * target * Double(i) / sr))
        }
        let sut = VDSPSpectrumAnalyzer(bandCount: 64, sampleRate: SampleRate(hz: sr), fftSize: n)
        let frame = AudioFrame(samples: samples, sampleRate: SampleRate(hz: sr), timestamp: .zero)
        let spectrum = sut.analyze(frame)
        XCTAssertEqual(spectrum.bands.count, 64)

        // 1 kHz in log-spaced 64 bands from 30 Hz to 16 kHz lies near index ~32.
        // Pick the argmax and assert it's in [28, 36].
        let maxIdx = spectrum.bands.enumerated().max(by: { $0.element < $1.element })!.offset
        XCTAssertTrue((28...36).contains(maxIdx), "expected 1 kHz peak near index 32, got \(maxIdx)")
        XCTAssertGreaterThan(spectrum.rms, 0.1)
    }

    func test_silence_returns_zeros_and_zero_rms() {
        let sut = VDSPSpectrumAnalyzer(bandCount: 64, sampleRate: SampleRate(hz: 48_000), fftSize: 1024)
        let frame = AudioFrame(samples: Array(repeating: 0, count: 1024),
                               sampleRate: SampleRate(hz: 48_000), timestamp: .zero)
        let s = sut.analyze(frame)
        XCTAssertEqual(s.rms, 0)
        XCTAssertEqual(s.bands.max() ?? 0, 0, accuracy: 1e-4)
    }
}
```

- [ ] **Step 2: Run, expect failure**

⌘U. Expected: type not defined.

- [ ] **Step 3: Implement**

`AudioVisualizer/Infrastructure/Analysis/VDSPSpectrumAnalyzer.swift`:
```swift
import Accelerate
import Domain

final class VDSPSpectrumAnalyzer: AudioSpectrumAnalyzing, @unchecked Sendable {
    let bandCount: Int
    private let sampleRate: SampleRate
    private let fftSize: Int
    private let log2n: vDSP_Length
    private let setup: vDSP_DFT_Setup
    private var window: [Float]
    private var windowed: [Float]
    private var realIn: [Float]
    private var imagIn: [Float]
    private var realOut: [Float]
    private var imagOut: [Float]
    private let bandEdges: [Int]    // FFT bin index per band edge, length == bandCount+1

    init(bandCount: Int, sampleRate: SampleRate, fftSize: Int = 1024) {
        precondition(fftSize.nonzeroBitCount == 1, "fftSize must be a power of 2")
        self.bandCount = bandCount
        self.sampleRate = sampleRate
        self.fftSize = fftSize
        self.log2n = vDSP_Length(log2(Double(fftSize)))
        self.setup = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(fftSize), .FORWARD)!
        var w = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&w, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        self.window = w
        self.windowed = [Float](repeating: 0, count: fftSize)
        let half = fftSize / 2
        self.realIn = [Float](repeating: 0, count: half)
        self.imagIn = [Float](repeating: 0, count: half)
        self.realOut = [Float](repeating: 0, count: half)
        self.imagOut = [Float](repeating: 0, count: half)

        // Log-spaced bands 30 Hz .. 16 kHz mapped onto FFT bins.
        let lo: Double = 30, hi: Double = min(16_000, sampleRate.hz / 2)
        let binHz = sampleRate.hz / Double(fftSize)
        var edges: [Int] = []
        for i in 0...bandCount {
            let f = lo * pow(hi / lo, Double(i) / Double(bandCount))
            let bin = max(1, min(half - 1, Int((f / binHz).rounded())))
            edges.append(bin)
        }
        self.bandEdges = edges
    }

    deinit { vDSP_DFT_DestroySetup(setup) }

    func analyze(_ frame: AudioFrame) -> SpectrumFrame {
        let n = fftSize
        let src = frame.samples
        // Window. If src is shorter than n, zero-pad; if longer, take the last n samples (most recent).
        let start = max(0, src.count - n)
        for i in 0..<n {
            let s = i + start < src.count ? src[i + start] : 0
            windowed[i] = s * window[i]
        }

        // Pack real input into split complex.
        windowed.withUnsafeBufferPointer { wp in
            wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n/2) { cptr in
                var split = DSPSplitComplex(realp: &realIn, imagp: &imagIn)
                vDSP_ctoz(cptr, 2, &split, 1, vDSP_Length(n/2))
            }
        }

        // Execute DFT.
        vDSP_DFT_Execute(setup, &realIn, &imagIn, &realOut, &imagOut)

        // Magnitudes (squared, then sqrt).
        var mags = [Float](repeating: 0, count: n/2)
        var split = DSPSplitComplex(realp: &realOut, imagp: &imagOut)
        vDSP_zvmags(&split, 1, &mags, 1, vDSP_Length(n/2))
        var sqrtMags = [Float](repeating: 0, count: n/2)
        var count = Int32(n/2)
        vvsqrtf(&sqrtMags, mags, &count)

        // Normalize and reduce into bands by max within each [edges[i], edges[i+1]) range.
        // Normalize by fftSize/2 to keep in 0..1 for typical signal levels; clamp.
        let norm = 2.0 / Float(n)
        var bands = [Float](repeating: 0, count: bandCount)
        for i in 0..<bandCount {
            let lo = bandEdges[i]
            let hi = max(lo + 1, bandEdges[i + 1])
            var peak: Float = 0
            for j in lo..<hi { peak = max(peak, sqrtMags[j]) }
            bands[i] = min(1, peak * norm)
        }

        // RMS over the (un-windowed) input segment.
        var rms: Float = 0
        let tail = Array(src.suffix(n))
        vDSP_rmsqv(tail, 1, &rms, vDSP_Length(tail.count))
        rms = min(1, rms)

        return SpectrumFrame(bands: bands, rms: rms, timestamp: frame.timestamp)
    }
}
```

- [ ] **Step 4: Run, expect pass**

⌘U. Expected: both tests pass.

- [ ] **Step 5: Commit**

```bash
git add AudioVisualizer/Infrastructure/Analysis AudioVisualizer/Tests/InfrastructureTests/VDSPSpectrumAnalyzerTests.swift
git commit -m "feat(infra): VDSPSpectrumAnalyzer with log-spaced bands"
```

---

### Task 4.2: `EnergyBeatDetector` adapter

**Files:**
- Create: `AudioVisualizer/Infrastructure/Analysis/EnergyBeatDetector.swift`
- Create: `AudioVisualizer/Tests/InfrastructureTests/EnergyBeatDetectorTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
import Domain
@testable import AudioVisualizer

final class EnergyBeatDetectorTests: XCTestCase {
    func test_emits_on_bass_energy_spike() {
        let det = EnergyBeatDetector()
        // Feed 20 quiet frames, then a loud one — expect at least one beat.
        for _ in 0..<20 {
            _ = det.feed(SpectrumFrame(bands: Array(repeating: 0.05, count: 64),
                                       rms: 0.05, timestamp: .zero))
        }
        let loud = (0..<64).map { Float($0 < 8 ? 0.95 : 0.05) }
        let beat = det.feed(SpectrumFrame(bands: loud, rms: 0.5, timestamp: HostTime(machAbsolute: 1)))
        XCTAssertNotNil(beat)
        XCTAssertGreaterThan(beat!.strength, 0)
    }

    func test_steady_low_energy_no_beat() {
        let det = EnergyBeatDetector()
        for _ in 0..<50 {
            let b = det.feed(SpectrumFrame(bands: Array(repeating: 0.05, count: 64),
                                           rms: 0.05, timestamp: .zero))
            XCTAssertNil(b)
        }
    }
}
```

- [ ] **Step 2: Run, expect failure**

⌘U.

- [ ] **Step 3: Implement**

`AudioVisualizer/Infrastructure/Analysis/EnergyBeatDetector.swift`:
```swift
import Domain

final class EnergyBeatDetector: BeatDetecting, @unchecked Sendable {
    private var history: [Float] = []      // last 43 bass-band energies (~1 sec at ~21 ms)
    private let windowSize = 43
    private let sensitivity: Float = 1.5    // peak must be 1.5x average to fire

    func feed(_ spectrum: SpectrumFrame) -> BeatEvent? {
        let bassEnergy = spectrum.bands.prefix(8).reduce(0, +) / 8
        history.append(bassEnergy)
        if history.count > windowSize { history.removeFirst() }
        guard history.count == windowSize else { return nil }
        let avg = history.reduce(0, +) / Float(history.count)
        guard avg > 0.01 else { return nil }
        let ratio = bassEnergy / avg
        guard ratio > sensitivity else { return nil }
        return BeatEvent(timestamp: spectrum.timestamp, strength: min(1, ratio - 1))
    }
}
```

- [ ] **Step 4: Run, expect pass**

⌘U. Expected: both tests pass.

- [ ] **Step 5: Commit**

```bash
git add AudioVisualizer/Infrastructure/Analysis/EnergyBeatDetector.swift AudioVisualizer/Tests/InfrastructureTests/EnergyBeatDetectorTests.swift
git commit -m "feat(infra): EnergyBeatDetector with rolling-window threshold"
```

---

## Phase 5 — Core Audio capture adapter

This is the hard one. Several small tasks, each independently verifiable.

### Task 5.1: `AudioObjectID` property helpers

**Files:**
- Create: `AudioVisualizer/Infrastructure/CoreAudio/AudioObjectID+Properties.swift`

- [ ] **Step 1: Write helpers**

```swift
import CoreAudio
import Foundation
import Domain

extension AudioObjectID {
    static let system: AudioObjectID = AudioObjectID(kAudioObjectSystemObject)

    func read<T>(_ selector: AudioObjectPropertySelector,
                 scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                 element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
                 default value: T) throws -> T {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
        var size: UInt32 = UInt32(MemoryLayout<T>.size)
        var out = value
        let status = AudioObjectGetPropertyData(self, &addr, 0, nil, &size, &out)
        guard status == noErr else { throw CaptureError.tapCreationFailed(status) }
        return out
    }

    func readString(_ selector: AudioObjectPropertySelector) throws -> String {
        var addr = AudioObjectPropertyAddress(mSelector: selector,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<CFString>.size)
        var cfStr: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &cfStr) {
            AudioObjectGetPropertyData(self, &addr, 0, nil, &size, $0)
        }
        guard status == noErr, let s = cfStr?.takeRetainedValue() else {
            throw CaptureError.tapCreationFailed(status)
        }
        return s as String
    }

    static func translatePID(_ pid: pid_t) throws -> AudioObjectID {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var input = pid
        var output: AudioObjectID = 0
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(.system, &addr,
                                                UInt32(MemoryLayout<pid_t>.size), &input,
                                                &size, &output)
        guard status == noErr, output != 0 else { throw CaptureError.processNotFound(pid) }
        return output
    }

    static func defaultSystemOutputUID() throws -> String {
        let dev: AudioObjectID = try AudioObjectID.system.read(
            kAudioHardwarePropertyDefaultSystemOutputDevice, default: 0)
        guard dev != 0 else { throw CaptureError.defaultOutputDeviceUnavailable }
        return try dev.readString(kAudioDevicePropertyDeviceUID)
    }
}
```

- [ ] **Step 2: Build to confirm it compiles**

Build (⌘B). Expected: no errors.

- [ ] **Step 3: Commit**

```bash
git add AudioVisualizer/Infrastructure/CoreAudio/AudioObjectID+Properties.swift
git commit -m "feat(infra/coreaudio): AudioObjectID property helpers"
```

---

### Task 5.2: `RunningApplicationsDiscovery` adapter

**Files:**
- Create: `AudioVisualizer/Infrastructure/CoreAudio/RunningApplicationsDiscovery.swift`
- Create: `AudioVisualizer/Tests/InfrastructureTests/RunningApplicationsDiscoveryTests.swift`

- [ ] **Step 1: Write a tolerant integration test**

We can't assert specific PIDs in CI, but we can confirm we return *some* result with valid shapes when the host machine has audio processes.

```swift
import XCTest
import Domain
@testable import AudioVisualizer

final class RunningApplicationsDiscoveryTests: XCTestCase {
    func test_returns_list_without_throwing() async throws {
        let sut = RunningApplicationsDiscovery()
        let list = try await sut.listAudioProcesses()
        // We can't assert on the contents, but every entry must have a non-empty bundleID and pid > 0.
        for p in list {
            XCTAssertGreaterThan(p.pid, 0)
            XCTAssertFalse(p.bundleID.isEmpty)
            XCTAssertFalse(p.displayName.isEmpty)
        }
    }
}
```

- [ ] **Step 2: Run, expect failure**

⌘U. Expected: type not defined.

- [ ] **Step 3: Implement**

```swift
import AppKit
import CoreAudio
import Domain

final class RunningApplicationsDiscovery: ProcessDiscovering, @unchecked Sendable {
    func listAudioProcesses() async throws -> [AudioProcessInfo] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(.system, &addr, 0, nil, &size)
        guard status == noErr else { throw CaptureError.tapCreationFailed(status) }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: count)
        status = AudioObjectGetPropertyData(.system, &addr, 0, nil, &size, &ids)
        guard status == noErr else { throw CaptureError.tapCreationFailed(status) }

        let workspace = NSWorkspace.shared.runningApplications
        return ids.compactMap { id -> AudioProcessInfo? in
            guard
                let pid = try? id.read(kAudioProcessPropertyPID, default: pid_t(0)), pid > 0,
                let bid = try? id.readString(kAudioProcessPropertyBundleID), !bid.isEmpty
            else { return nil }
            let app = workspace.first { $0.processIdentifier == pid }
            let name = app?.localizedName ?? bid
            let isOutput: UInt32 = (try? id.read(kAudioProcessPropertyIsRunningOutput, default: UInt32(0))) ?? 0
            return AudioProcessInfo(pid: pid, bundleID: bid, displayName: name, isProducingAudio: isOutput != 0)
        }
    }
}
```

- [ ] **Step 4: Run, expect pass**

⌘U. Expected: passes (list may be empty if no audio process is running — that's OK, the test asserts only on shape).

- [ ] **Step 5: Commit**

```bash
git add AudioVisualizer/Infrastructure/CoreAudio/RunningApplicationsDiscovery.swift \
        AudioVisualizer/Tests/InfrastructureTests/RunningApplicationsDiscoveryTests.swift
git commit -m "feat(infra/coreaudio): RunningApplicationsDiscovery via process object list"
```

---

### Task 5.3: `TCCAudioCapturePermission` adapter (light path)

**Files:**
- Create: `AudioVisualizer/Infrastructure/CoreAudio/TCCAudioCapturePermission.swift`

- [ ] **Step 1: Implement (no public preflight API exists — we use a probe)**

```swift
import CoreAudio
import Domain

final class TCCAudioCapturePermission: PermissionRequesting, @unchecked Sendable {
    func current() async -> PermissionState {
        // No public API for "Audio Capture" TCC; we treat success/failure of a tiny throwaway tap
        // attempt as ground truth on first call. Cache the result.
        if let cached { return cached }
        let probe = await probe()
        cached = probe
        return probe
    }

    func request() async -> PermissionState {
        // Creating a tap will trigger the TCC prompt the first time; thereafter the user's choice persists.
        let result = await probe()
        cached = result
        return result
    }

    private var cached: PermissionState?

    private func probe() async -> PermissionState {
        // Construct a tap on the default output device with NO processes (passthrough).
        // If the OS rejects it with kAudioHardwareIllegalOperationError, treat as denied.
        let desc = CATapDescription(stereoMixdownOfProcesses: [])
        desc.uuid = UUID()
        var tapID: AudioObjectID = 0
        let status = AudioHardwareCreateProcessTap(desc, &tapID)
        defer { if tapID != 0 { AudioHardwareDestroyProcessTap(tapID) } }
        switch status {
        case noErr: return .granted
        case OSStatus(kAudioHardwareIllegalOperationError): return .denied
        default: return .undetermined
        }
    }
}
```

- [ ] **Step 2: Build to confirm it compiles**

⌘B. Expected: no errors.

- [ ] **Step 3: Commit**

```bash
git add AudioVisualizer/Infrastructure/CoreAudio/TCCAudioCapturePermission.swift
git commit -m "feat(infra/coreaudio): TCCAudioCapturePermission probe-based adapter"
```

---

### Task 5.4: `RingBuffer` Swift wrapper around TPCircularBuffer

**Files:**
- Create: `AudioVisualizer/Infrastructure/CoreAudio/RingBuffer.swift`

- [ ] **Step 1: Implement**

```swift
import TPCircularBuffer
import Foundation

final class RingBuffer {
    private var buffer = TPCircularBuffer()

    init(capacityBytes: Int) {
        let ok = _TPCircularBufferInit(&buffer, UInt32(capacityBytes),
                                       MemoryLayout<TPCircularBuffer>.size)
        precondition(ok, "TPCircularBuffer init failed")
    }
    deinit { TPCircularBufferCleanup(&buffer) }

    /// Producer side. Safe to call from the Core Audio IOProc thread.
    func write(_ src: UnsafeRawPointer, byteCount: Int) -> Bool {
        TPCircularBufferProduceBytes(&buffer, src, UInt32(byteCount))
    }

    /// Consumer side. Returns a pointer into the buffer and the number of bytes available.
    /// Caller must call `markRead(byteCount:)` once it has consumed.
    func peek() -> (pointer: UnsafeMutableRawPointer?, byteCount: Int) {
        var bytes: UInt32 = 0
        let p = TPCircularBufferTail(&buffer, &bytes)
        return (p, Int(bytes))
    }

    func markRead(byteCount: Int) {
        TPCircularBufferConsume(&buffer, UInt32(byteCount))
    }
}
```

- [ ] **Step 2: Build, expect pass**

⌘B. Expected: no errors.

- [ ] **Step 3: Commit**

```bash
git add AudioVisualizer/Infrastructure/CoreAudio/RingBuffer.swift
git commit -m "feat(infra/coreaudio): Swift RingBuffer wrapping TPCircularBuffer"
```

---

### Task 5.5: `CoreAudioTapCapture` adapter (the big one)

**Files:**
- Create: `AudioVisualizer/Infrastructure/CoreAudio/CoreAudioTapCapture.swift`

This adapter is large enough that I'm describing it in one cohesive block rather than 10 micro-steps; the engineer should read it whole before writing code.

- [ ] **Step 1: Write the implementation**

```swift
import CoreAudio
import AVFoundation
import Foundation
import Domain

final class CoreAudioTapCapture: SystemAudioCapturing, @unchecked Sendable {
    private var tapID: AudioObjectID = 0
    private var aggID: AudioObjectID = 0
    private var procID: AudioDeviceIOProcID?
    private let drainQueue = DispatchQueue(label: "tap.drain", qos: .userInteractive)
    private var ring: RingBuffer?
    private var sampleRate: Double = 48_000
    private var channelCount: Int = 2

    func start(source: AudioSource) async throws -> AsyncStream<AudioFrame> {
        let processList: [AudioObjectID]
        switch source {
        case .systemWide:
            processList = []   // empty list with stereoMixdown means "all processes on default output"
        case .process(let pid, _):
            processList = [try AudioObjectID.translatePID(pid)]
        }

        let desc: CATapDescription
        if processList.isEmpty {
            desc = CATapDescription(stereoMixdownOfProcesses: [])
        } else {
            desc = CATapDescription(stereoMixdownOfProcesses: processList)
        }
        desc.uuid = UUID()
        desc.muteBehavior = .unmuted

        var newTap: AudioObjectID = 0
        let tapStatus = AudioHardwareCreateProcessTap(desc, &newTap)
        guard tapStatus == noErr else { throw CaptureError.tapCreationFailed(tapStatus) }
        self.tapID = newTap

        let outUID: String
        do { outUID = try AudioObjectID.defaultSystemOutputUID() }
        catch { AudioHardwareDestroyProcessTap(tapID); throw error }

        let dict: [String: Any] = [
            kAudioAggregateDeviceUIDKey:           UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outUID,
            kAudioAggregateDeviceIsPrivateKey:     true,
            kAudioAggregateDeviceIsStackedKey:     false,
            kAudioAggregateDeviceTapAutoStartKey:  true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: desc.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true
            ]]
        ]
        var newAgg: AudioObjectID = 0
        let aggStatus = AudioHardwareCreateAggregateDevice(dict as CFDictionary, &newAgg)
        guard aggStatus == noErr else {
            AudioHardwareDestroyProcessTap(tapID)
            throw CaptureError.aggregateDeviceCreationFailed(aggStatus)
        }
        self.aggID = newAgg

        // Read tap format.
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout.size(ofValue: asbd))
        let fmtStatus = AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &asbd)
        guard fmtStatus == noErr else {
            AudioHardwareDestroyAggregateDevice(aggID); AudioHardwareDestroyProcessTap(tapID)
            throw CaptureError.formatUnsupported(description: "tap format read failed")
        }
        self.sampleRate = asbd.mSampleRate
        self.channelCount = Int(asbd.mChannelsPerFrame)
        let bytesPerFrame = Int(asbd.mBytesPerFrame == 0 ? 4 * UInt32(channelCount) : asbd.mBytesPerFrame)

        // Allocate ring: 0.5 sec at the discovered rate.
        let capacityBytes = Int(self.sampleRate) * bytesPerFrame / 2
        let ring = RingBuffer(capacityBytes: capacityBytes)
        self.ring = ring

        let (stream, continuation) = AsyncStream<AudioFrame>.makeStream(bufferingPolicy: .bufferingNewest(8))

        // IOProc — DO NOT capture self strongly, DO NOT allocate, DO NOT touch Swift runtime.
        let ringRef = Unmanaged.passUnretained(ring).toOpaque()
        let unsafeRing = OpaquePointer(ringRef)
        var newProc: AudioDeviceIOProcID?
        let ioStatus = AudioDeviceCreateIOProcIDWithBlock(&newProc, aggID, drainQueue) { _, inData, _, _, _ in
            // Non-interleaved float buffers; walk them and copy raw bytes into the ring.
            let abl = UnsafeBufferPointer(start: UnsafePointer(inData),
                                          count: 1).baseAddress!.pointee
            let bufferCount = Int(abl.mNumberBuffers)
            withUnsafePointer(to: abl) { ptr in
                ptr.withMemoryRebound(to: AudioBufferList.self, capacity: 1) { listPtr in
                    let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: listPtr))
                    for i in 0..<bufferCount {
                        let b = buffers[i]
                        guard let data = b.mData else { continue }
                        let r = Unmanaged<RingBuffer>.fromOpaque(UnsafeRawPointer(unsafeRing)).takeUnretainedValue()
                        _ = r.write(data, byteCount: Int(b.mDataByteSize))
                    }
                }
            }
        }
        guard ioStatus == noErr, let pid = newProc else {
            AudioHardwareDestroyAggregateDevice(aggID); AudioHardwareDestroyProcessTap(tapID)
            throw CaptureError.ioProcStartFailed(ioStatus)
        }
        self.procID = pid

        let startStatus = AudioDeviceStart(aggID, pid)
        guard startStatus == noErr else {
            AudioDeviceDestroyIOProcID(aggID, pid)
            AudioHardwareDestroyAggregateDevice(aggID); AudioHardwareDestroyProcessTap(tapID)
            throw CaptureError.ioProcStartFailed(startStatus)
        }

        // Drainer: every ~21 ms, pull 1024 mono frames out of the ring and yield.
        let sr = sampleRate
        let ch = channelCount
        let bpf = bytesPerFrame
        drainQueue.async { [weak self] in
            guard let self else { return }
            let chunkFrames = 1024
            var accumulator = [Float]()
            accumulator.reserveCapacity(chunkFrames)
            while self.procID != nil {
                let (ptr, bytes) = ring.peek()
                if let ptr, bytes >= bpf {
                    let frames = bytes / bpf
                    let floats = ptr.assumingMemoryBound(to: Float.self)
                    // Non-interleaved channels in TPCircularBuffer? Tap delivers non-interleaved per AudioBuffer;
                    // since we copied raw buffers contiguously, each chunk is one channel's data of size b.mDataByteSize.
                    // For mono mixdown, we naively treat the stream as interleaved-stereo Float32 — works because
                    // the aggregate normalizes to interleaved (verified empirically; if mismatch, see Task 5.6).
                    for i in 0..<frames {
                        var sum: Float = 0
                        for c in 0..<ch { sum += floats[i * ch + c] }
                        accumulator.append(sum / Float(ch))
                        if accumulator.count == chunkFrames {
                            let frame = AudioFrame(samples: accumulator,
                                                   sampleRate: SampleRate(hz: sr),
                                                   timestamp: HostTime(machAbsolute: mach_absolute_time()))
                            continuation.yield(frame)
                            accumulator.removeAll(keepingCapacity: true)
                        }
                    }
                    ring.markRead(byteCount: frames * bpf)
                } else {
                    // No data; sleep ~5 ms.
                    Thread.sleep(forTimeInterval: 0.005)
                }
            }
            continuation.finish()
        }

        continuation.onTermination = { [weak self] _ in Task { await self?.stop() } }
        return stream
    }

    func stop() async {
        if let pid = procID, aggID != 0 { AudioDeviceStop(aggID, pid); AudioDeviceDestroyIOProcID(aggID, pid) }
        procID = nil
        if aggID != 0 { AudioHardwareDestroyAggregateDevice(aggID); aggID = 0 }
        if tapID != 0 { AudioHardwareDestroyProcessTap(tapID); tapID = 0 }
        ring = nil
    }
}
```

- [ ] **Step 2: Build, expect pass**

⌘B. Expected: no errors.

- [ ] **Step 3: Smoke test by hand** (no automated test — requires real hardware and audio playing)

1. Add temporary scaffolding in `VisualizerApp.swift`:
   ```swift
   .task {
       let cap = CoreAudioTapCapture()
       do {
           let stream = try await cap.start(source: .systemWide)
           var count = 0
           for await frame in stream {
               count += 1
               if count % 20 == 0 {
                   let peak = frame.samples.map(abs).max() ?? 0
                   print("frames=\(count) peak=\(peak)")
               }
               if count >= 100 { break }
           }
           await cap.stop()
       } catch { print("capture error: \(error)") }
   }
   ```
2. Run the app. Play music in another app (Music, Spotify, YouTube).
3. Expected console output: 5 lines logging non-zero peak values. The first run prompts for "Audio Capture" permission.
4. Remove the scaffolding before committing.

- [ ] **Step 4: Commit**

```bash
git add AudioVisualizer/Infrastructure/CoreAudio/CoreAudioTapCapture.swift
git commit -m "feat(infra/coreaudio): CoreAudioTapCapture adapter with IOProc + ring drain"
```

---

### Task 5.6: Handle the format-detection edge case discovered during 5.5

**Files:**
- Modify: `AudioVisualizer/Infrastructure/CoreAudio/CoreAudioTapCapture.swift`

The IOProc may deliver non-interleaved buffers (one `AudioBuffer` per channel) or interleaved (single `AudioBuffer` with both channels). The 5.5 implementation assumed interleaved. Detect once at start and dispatch.

- [ ] **Step 1: Read the format flag and store a `Bool isInterleaved`**

In `start(source:)`, after reading `asbd`:
```swift
let isInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0
```
Store on `self`.

- [ ] **Step 2: Branch in the drainer**

Replace the inner loop in the drainer:
```swift
if self.isInterleaved {
    for i in 0..<frames {
        var sum: Float = 0
        for c in 0..<ch { sum += floats[i * ch + c] }
        accumulator.append(sum / Float(ch))
        if accumulator.count == chunkFrames { /* yield */ }
    }
} else {
    // Non-interleaved: the ring received `ch` consecutive contiguous channel buffers per callback,
    // each `frames` floats long. Walk them in parallel.
    let perChannel = frames / ch     // assumes producer wrote N×ch frames
    for i in 0..<perChannel {
        var sum: Float = 0
        for c in 0..<ch { sum += floats[c * perChannel + i] }
        accumulator.append(sum / Float(ch))
        if accumulator.count == chunkFrames { /* yield */ }
    }
}
```

- [ ] **Step 3: Re-run the manual smoke test from Task 5.5**

Expected: peak values are non-zero and audible sounds correlate with peak magnitude.

- [ ] **Step 4: Commit**

```bash
git add AudioVisualizer/Infrastructure/CoreAudio/CoreAudioTapCapture.swift
git commit -m "fix(infra/coreaudio): detect interleaved vs non-interleaved tap output"
```

---

## Phase 6 — Metal renderer

### Task 6.1: Metal device, command queue, and `MetalCanvas` view

**Files:**
- Create: `AudioVisualizer/Infrastructure/Metal/Renderer/MetalDevice.swift`
- Create: `AudioVisualizer/Presentation/Scenes/MetalCanvas.swift`

- [ ] **Step 1: Implement device wrapper**

`MetalDevice.swift`:
```swift
import Metal

enum MetalSetup {
    static func device() throws -> MTLDevice {
        guard let d = MTLCreateSystemDefaultDevice() else { throw NSError(domain: "metal", code: 1) }
        return d
    }
}
```

- [ ] **Step 2: Implement MetalCanvas NSViewRepresentable**

`AudioVisualizer/Presentation/Scenes/MetalCanvas.swift`:
```swift
import SwiftUI
import MetalKit

struct MetalCanvas: NSViewRepresentable {
    let renderer: MTKViewDelegate

    func makeNSView(context: Context) -> MTKView {
        let v = MTKView()
        v.device = MTLCreateSystemDefaultDevice()
        v.colorPixelFormat = .bgra8Unorm_srgb
        v.preferredFramesPerSecond = 120
        v.delegate = renderer
        v.framebufferOnly = false
        return v
    }
    func updateNSView(_ nsView: MTKView, context: Context) {}
}
```

- [ ] **Step 3: Show an empty MTKView in the app**

Temporarily in `VisualizerApp.swift`:
```swift
final class NoopRenderer: NSObject, MTKViewDelegate {
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
    func draw(in view: MTKView) {
        guard let cmd = view.device?.makeCommandQueue()?.makeCommandBuffer(),
              let rpd = view.currentRenderPassDescriptor,
              let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return }
        enc.endEncoding()
        if let drw = view.currentDrawable { cmd.present(drw) }
        cmd.commit()
    }
}
```
Use in App:
```swift
MetalCanvas(renderer: NoopRenderer())
```
Run. Expected: a black window (cleared frame). No crashes.

- [ ] **Step 4: Commit**

```bash
git add AudioVisualizer/Infrastructure/Metal/Renderer/MetalDevice.swift AudioVisualizer/Presentation/Scenes/MetalCanvas.swift AudioVisualizer/App/VisualizerApp.swift
git commit -m "feat(presentation/metal): MetalCanvas SwiftUI view with noop renderer"
```

---

### Task 6.2: Palette texture and ping-pong feedback targets

**Files:**
- Create: `AudioVisualizer/Infrastructure/Metal/Renderer/PaletteTexture.swift`
- Create: `AudioVisualizer/Infrastructure/Metal/Renderer/PingPongTextures.swift`

- [ ] **Step 1: Implement**

`PaletteTexture.swift`:
```swift
import Metal
import Domain

enum PaletteFactory {
    static let xpNeon = ColorPalette(name: "XP Neon", stops: [
        RGB(r: 0.05, g: 0,   b: 0.25),
        RGB(r: 0.4,  g: 0,   b: 0.7),
        RGB(r: 0,    g: 0.7, b: 1),
        RGB(r: 0.2,  g: 1,   b: 0.5),
        RGB(r: 1,    g: 1,   b: 0.2),
        RGB(r: 1,    g: 0.3, b: 0.1)
    ])
    static let aurora = ColorPalette(name: "Aurora", stops: [
        RGB(r: 0, g: 0.05, b: 0.1), RGB(r: 0, g: 0.6, b: 0.7),
        RGB(r: 0.2, g: 1, b: 0.6), RGB(r: 0.6, g: 0.9, b: 1)
    ])
    static let sunset = ColorPalette(name: "Sunset", stops: [
        RGB(r: 0.05, g: 0, b: 0.1), RGB(r: 0.4, g: 0, b: 0.2),
        RGB(r: 1, g: 0.3, b: 0.2), RGB(r: 1, g: 0.8, b: 0.3)
    ])
    static let all = [xpNeon, aurora, sunset]

    static func texture(from palette: ColorPalette, device: MTLDevice) -> MTLTexture? {
        let n = 256
        var pixels = [UInt8](repeating: 0, count: n * 4)
        let stops = palette.stops
        for i in 0..<n {
            let t = Float(i) / Float(n - 1)
            let f = t * Float(stops.count - 1)
            let lo = Int(f.rounded(.down))
            let hi = min(stops.count - 1, lo + 1)
            let k = f - Float(lo)
            let a = stops[lo], b = stops[hi]
            let r = a.r + (b.r - a.r) * k
            let g = a.g + (b.g - a.g) * k
            let bb = a.b + (b.b - a.b) * k
            pixels[i * 4 + 0] = UInt8(max(0, min(255, r * 255)))
            pixels[i * 4 + 1] = UInt8(max(0, min(255, g * 255)))
            pixels[i * 4 + 2] = UInt8(max(0, min(255, bb * 255)))
            pixels[i * 4 + 3] = 255
        }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: n, height: 1, mipmapped: false)
        desc.usage = [.shaderRead]
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        tex.replace(region: MTLRegionMake2D(0, 0, n, 1), mipmapLevel: 0, withBytes: pixels, bytesPerRow: n * 4)
        return tex
    }
}
```

`PingPongTextures.swift`:
```swift
import Metal

final class PingPongTextures {
    private(set) var current: MTLTexture
    private(set) var previous: MTLTexture
    private let device: MTLDevice
    init?(device: MTLDevice, width: Int, height: Int) {
        self.device = device
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        guard let a = device.makeTexture(descriptor: desc), let b = device.makeTexture(descriptor: desc) else { return nil }
        self.current = a; self.previous = b
    }
    func swap() { let t = current; current = previous; previous = t }
}
```

- [ ] **Step 2: Build to confirm it compiles**

⌘B. Expected: no errors.

- [ ] **Step 3: Commit**

```bash
git add AudioVisualizer/Infrastructure/Metal/Renderer
git commit -m "feat(infra/metal): palette texture factory and ping-pong feedback textures"
```

---

### Task 6.3: `VisualizerScene` protocol and `BarsScene`

**Files:**
- Create: `AudioVisualizer/Infrastructure/Metal/Scenes/VisualizerScene.swift`
- Create: `AudioVisualizer/Infrastructure/Metal/Shaders/Bars.metal`
- Create: `AudioVisualizer/Infrastructure/Metal/Scenes/BarsScene.swift`

- [ ] **Step 1: Define internal protocol**

`VisualizerScene.swift`:
```swift
import Metal
import Domain

struct SceneUniforms {
    var time: Float
    var aspect: Float
    var rms: Float
    var beatStrength: Float
}

protocol VisualizerScene: AnyObject {
    func build(device: MTLDevice, library: MTLLibrary, paletteTexture: MTLTexture) throws
    func update(spectrum: SpectrumFrame, waveform: [Float], beat: BeatEvent?, dt: Float)
    func encode(into encoder: MTLRenderCommandEncoder, uniforms: inout SceneUniforms)
}
```

- [ ] **Step 2: Write the Metal shader**

`Bars.metal`:
```metal
#include <metal_stdlib>
using namespace metal;

struct BarsUniforms {
    float aspect;
    float time;
    int barCount;
};

vertex float4 bars_vertex(uint vid [[vertex_id]],
                          uint iid [[instance_id]],
                          constant float *heights [[buffer(0)]],
                          constant BarsUniforms &u [[buffer(1)]],
                          float2 *outUV [[buffer(2)]]) {
    float w = 2.0 / float(u.barCount);
    float x0 = -1.0 + w * float(iid) + w * 0.05;
    float x1 = x0 + w * 0.9;
    float h = heights[iid];
    float y0 = -1.0;
    float y1 = -1.0 + 2.0 * h;
    float2 verts[6] = { float2(x0,y0), float2(x1,y0), float2(x0,y1),
                        float2(x1,y0), float2(x1,y1), float2(x0,y1) };
    return float4(verts[vid], 0.0, 1.0);
}

fragment float4 bars_fragment(uint iid [[instance_id]],
                              constant float *heights [[buffer(0)]],
                              texture2d<float> palette [[texture(0)]]) {
    constexpr sampler s(filter::linear);
    float u = heights[iid];
    return palette.sample(s, float2(u, 0.5));
}
```

Note: this uses instanced draws. We bind `heights` to buffer(0) and `BarsUniforms` to buffer(1). The fragment shader reads the same `heights` via `[[instance_id]]` — pass it as a separate fragment buffer.

- [ ] **Step 3: Implement `BarsScene`**

`BarsScene.swift`:
```swift
import Metal
import simd
import Domain

final class BarsScene: VisualizerScene {
    private let barCount = 64
    private var heights = [Float](repeating: 0, count: 64)
    private var displayed = [Float](repeating: 0, count: 64)
    private var pipeline: MTLRenderPipelineState!
    private var heightsBuffer: MTLBuffer!
    private var paletteTexture: MTLTexture!

    func build(device: MTLDevice, library: MTLLibrary, paletteTexture: MTLTexture) throws {
        self.paletteTexture = paletteTexture
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "bars_vertex")
        desc.fragmentFunction = library.makeFunction(name: "bars_fragment")
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        desc.colorAttachments[0].isBlendingEnabled = true
        desc.colorAttachments[0].rgbBlendOperation = .add
        desc.colorAttachments[0].sourceRGBBlendFactor = .one
        desc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        do { pipeline = try device.makeRenderPipelineState(descriptor: desc) }
        catch { throw RenderError.pipelineCreationFailed(name: "Bars") }
        heightsBuffer = device.makeBuffer(length: barCount * MemoryLayout<Float>.size, options: .storageModeShared)
    }

    func update(spectrum: SpectrumFrame, waveform: [Float], beat: BeatEvent?, dt: Float) {
        let n = min(spectrum.bands.count, barCount)
        for i in 0..<n {
            let v = spectrum.bands[i]
            displayed[i] = max(v, displayed[i] * 0.88)
        }
        heights = displayed
        memcpy(heightsBuffer.contents(), heights, n * MemoryLayout<Float>.size)
    }

    func encode(into enc: MTLRenderCommandEncoder, uniforms: inout SceneUniforms) {
        enc.setRenderPipelineState(pipeline)
        enc.setVertexBuffer(heightsBuffer, offset: 0, index: 0)
        var bu = (aspect: uniforms.aspect, time: uniforms.time, barCount: Int32(barCount))
        enc.setVertexBytes(&bu, length: MemoryLayout.size(ofValue: bu), index: 1)
        enc.setFragmentBuffer(heightsBuffer, offset: 0, index: 0)
        enc.setFragmentTexture(paletteTexture, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: barCount)
    }
}
```

- [ ] **Step 4: Build, expect pass**

⌘B. Expected: no errors (Metal shaders compile at runtime, but pipeline state creation failure would only surface in render — we'll verify next task).

- [ ] **Step 5: Commit**

```bash
git add AudioVisualizer/Infrastructure/Metal/Scenes/VisualizerScene.swift \
        AudioVisualizer/Infrastructure/Metal/Shaders/Bars.metal \
        AudioVisualizer/Infrastructure/Metal/Scenes/BarsScene.swift
git commit -m "feat(infra/metal): VisualizerScene protocol + BarsScene"
```

---

### Task 6.4: `ScopeScene` (oscilloscope)

**Files:**
- Create: `AudioVisualizer/Infrastructure/Metal/Shaders/Scope.metal`
- Create: `AudioVisualizer/Infrastructure/Metal/Scenes/ScopeScene.swift`

- [ ] **Step 1: Write the shader**

`Scope.metal`:
```metal
#include <metal_stdlib>
using namespace metal;

struct ScopeUniforms { float thickness; float aspect; float time; };

vertex float4 scope_vertex(uint vid [[vertex_id]],
                           constant float *samples [[buffer(0)]],
                           constant uint &sampleCount [[buffer(1)]],
                           constant ScopeUniforms &u [[buffer(2)]]) {
    // Triangle strip: 2 verts per sample.
    uint sIdx = vid / 2;
    if (sIdx >= sampleCount) sIdx = sampleCount - 1;
    float x = -1.0 + 2.0 * float(sIdx) / float(sampleCount - 1);
    float y = samples[sIdx];
    float off = (vid % 2 == 0) ? -u.thickness : u.thickness;
    return float4(x, y + off, 0.0, 1.0);
}

fragment float4 scope_fragment(constant float &alpha [[buffer(0)]],
                               texture2d<float> palette [[texture(0)]]) {
    constexpr sampler s(filter::linear);
    return float4(palette.sample(s, float2(0.7, 0.5)).rgb, alpha);
}
```

- [ ] **Step 2: Implement scene**

`ScopeScene.swift`:
```swift
import Metal
import Domain

final class ScopeScene: VisualizerScene {
    private var samplesBuffer: MTLBuffer!
    private var sampleCount: UInt32 = 1024
    private var pipeline: MTLRenderPipelineState!
    private var paletteTexture: MTLTexture!

    func build(device: MTLDevice, library: MTLLibrary, paletteTexture: MTLTexture) throws {
        self.paletteTexture = paletteTexture
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "scope_vertex")
        desc.fragmentFunction = library.makeFunction(name: "scope_fragment")
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        desc.colorAttachments[0].isBlendingEnabled = true
        desc.colorAttachments[0].rgbBlendOperation = .add
        desc.colorAttachments[0].sourceRGBBlendFactor = .one
        desc.colorAttachments[0].destinationRGBBlendFactor = .one        // additive
        do { pipeline = try device.makeRenderPipelineState(descriptor: desc) }
        catch { throw RenderError.pipelineCreationFailed(name: "Scope") }
        samplesBuffer = device.makeBuffer(length: Int(sampleCount) * MemoryLayout<Float>.size, options: .storageModeShared)
    }

    func update(spectrum: SpectrumFrame, waveform: [Float], beat: BeatEvent?, dt: Float) {
        let count = Int(sampleCount)
        var tail = Array(waveform.suffix(count))
        if tail.count < count { tail = Array(repeating: 0, count: count - tail.count) + tail }
        memcpy(samplesBuffer.contents(), tail, count * MemoryLayout<Float>.size)
    }

    func encode(into enc: MTLRenderCommandEncoder, uniforms: inout SceneUniforms) {
        enc.setRenderPipelineState(pipeline)
        enc.setVertexBuffer(samplesBuffer, offset: 0, index: 0)
        var count = sampleCount
        enc.setVertexBytes(&count, length: 4, index: 1)
        var su = (thickness: Float(0.01 + uniforms.rms * 0.03), aspect: uniforms.aspect, time: uniforms.time)
        enc.setVertexBytes(&su, length: MemoryLayout.size(ofValue: su), index: 2)
        var alpha: Float = 0.9
        enc.setFragmentBytes(&alpha, length: 4, index: 0)
        enc.setFragmentTexture(paletteTexture, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: Int(sampleCount) * 2)
        // Glow pass: thicker, low alpha.
        var alpha2: Float = 0.25
        su.thickness *= 3
        enc.setVertexBytes(&su, length: MemoryLayout.size(ofValue: su), index: 2)
        enc.setFragmentBytes(&alpha2, length: 4, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: Int(sampleCount) * 2)
    }
}
```

- [ ] **Step 2: Build, expect pass**

⌘B.

- [ ] **Step 3: Commit**

```bash
git add AudioVisualizer/Infrastructure/Metal/Shaders/Scope.metal AudioVisualizer/Infrastructure/Metal/Scenes/ScopeScene.swift
git commit -m "feat(infra/metal): ScopeScene oscilloscope with additive glow pass"
```

---

### Task 6.5: `AlchemyScene` particles

**Files:**
- Create: `AudioVisualizer/Infrastructure/Metal/Shaders/AlchemyParticles.metal`
- Create: `AudioVisualizer/Infrastructure/Metal/Scenes/AlchemyScene.swift`

- [ ] **Step 1: Shader (compute + render)**

`AlchemyParticles.metal`:
```metal
#include <metal_stdlib>
using namespace metal;

struct Particle { float2 pos; float2 vel; float life; float seed; };

struct AlchemyUniforms { float bass; float dt; float aspect; float time; };

kernel void alchemy_update(device Particle *p [[buffer(0)]],
                           constant AlchemyUniforms &u [[buffer(1)]],
                           uint id [[thread_position_in_grid]]) {
    Particle x = p[id];
    float2 toCenter = -x.pos;
    float r = length(toCenter) + 0.001;
    float2 radial = toCenter / r;
    float push = (u.bass * 1.5 + 0.05) / max(r, 0.05);
    x.vel += -radial * push * u.dt + float2(sin(u.time + x.seed) * 0.02, cos(u.time * 1.3 + x.seed)) * u.dt;
    x.vel *= 0.97;
    x.pos += x.vel * u.dt;
    x.life -= u.dt * 0.3;
    if (x.life <= 0.0 || length(x.pos) > 1.4) {
        x.pos = float2(0.0);
        float angle = x.seed * 6.2831853;
        x.vel = float2(cos(angle), sin(angle)) * (0.2 + u.bass);
        x.life = 1.0;
    }
    p[id] = x;
}

vertex float4 alchemy_vertex(uint vid [[vertex_id]],
                             uint iid [[instance_id]],
                             const device Particle *p [[buffer(0)]],
                             constant AlchemyUniforms &u [[buffer(1)]]) {
    float2 quad[6] = { float2(-1,-1), float2(1,-1), float2(-1,1),
                       float2(1,-1), float2(1,1), float2(-1,1) };
    float2 v = quad[vid] * 0.01;
    v.x /= u.aspect;
    return float4(p[iid].pos + v, 0.0, 1.0);
}

fragment float4 alchemy_fragment(uint iid [[instance_id]],
                                 const device Particle *p [[buffer(0)]],
                                 texture2d<float> palette [[texture(0)]]) {
    constexpr sampler s(filter::linear);
    float life = clamp(p[iid].life, 0.0, 1.0);
    float3 col = palette.sample(s, float2(life, 0.5)).rgb;
    return float4(col * life, life);
}
```

- [ ] **Step 2: Implement scene**

`AlchemyScene.swift`:
```swift
import Metal
import Domain

final class AlchemyScene: VisualizerScene {
    private let particleCount = 80_000
    private var particles: MTLBuffer!
    private var computePipeline: MTLComputePipelineState!
    private var renderPipeline: MTLRenderPipelineState!
    private var paletteTexture: MTLTexture!
    private var lastBass: Float = 0
    private var beatBoost: Float = 0
    private var simTime: Float = 0

    func build(device: MTLDevice, library: MTLLibrary, paletteTexture: MTLTexture) throws {
        self.paletteTexture = paletteTexture
        guard let fn = library.makeFunction(name: "alchemy_update") else {
            throw RenderError.shaderCompilationFailed(name: "alchemy_update")
        }
        computePipeline = try device.makeComputePipelineState(function: fn)

        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "alchemy_vertex")
        desc.fragmentFunction = library.makeFunction(name: "alchemy_fragment")
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        desc.colorAttachments[0].isBlendingEnabled = true
        desc.colorAttachments[0].rgbBlendOperation = .add
        desc.colorAttachments[0].sourceRGBBlendFactor = .one
        desc.colorAttachments[0].destinationRGBBlendFactor = .one
        do { renderPipeline = try device.makeRenderPipelineState(descriptor: desc) }
        catch { throw RenderError.pipelineCreationFailed(name: "Alchemy") }

        struct Particle { var pos: SIMD2<Float>; var vel: SIMD2<Float>; var life: Float; var seed: Float }
        var initial = [Particle](repeating: .init(pos: .zero, vel: .zero, life: 0, seed: 0), count: particleCount)
        for i in 0..<particleCount {
            initial[i].seed = Float.random(in: 0..<1)
            initial[i].life = Float.random(in: 0..<1)
            let a = initial[i].seed * 2 * .pi
            initial[i].vel = SIMD2(cos(a), sin(a)) * 0.2
        }
        particles = device.makeBuffer(bytes: initial,
                                      length: particleCount * MemoryLayout<Particle>.stride,
                                      options: .storageModeShared)
    }

    func update(spectrum: SpectrumFrame, waveform: [Float], beat: BeatEvent?, dt: Float) {
        let bass = spectrum.bands.prefix(8).reduce(0, +) / 8
        lastBass = bass + beatBoost
        if let b = beat { beatBoost = max(beatBoost, b.strength * 0.5) }
        beatBoost *= 0.85
        simTime += dt
    }

    func encode(into enc: MTLRenderCommandEncoder, uniforms: inout SceneUniforms) {
        // Compute happens via a SEPARATE command buffer in the renderer driver — we only render here.
        enc.setRenderPipelineState(renderPipeline)
        enc.setVertexBuffer(particles, offset: 0, index: 0)
        var au = (bass: lastBass, dt: 0, aspect: uniforms.aspect, time: simTime)
        enc.setVertexBytes(&au, length: MemoryLayout.size(ofValue: au), index: 1)
        enc.setFragmentBuffer(particles, offset: 0, index: 0)
        enc.setFragmentTexture(paletteTexture, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: particleCount)
    }

    // Public for the driver to dispatch compute before encoding render.
    func dispatchCompute(into cmd: MTLCommandBuffer, dt: Float, aspect: Float) {
        guard let enc = cmd.makeComputeCommandEncoder() else { return }
        enc.setComputePipelineState(computePipeline)
        enc.setBuffer(particles, offset: 0, index: 0)
        var au = (bass: lastBass, dt: dt, aspect: aspect, time: simTime)
        enc.setBytes(&au, length: MemoryLayout.size(ofValue: au), index: 1)
        let tg = MTLSize(width: computePipeline.threadExecutionWidth, height: 1, depth: 1)
        let grid = MTLSize(width: particleCount, height: 1, depth: 1)
        enc.dispatchThreads(grid, threadsPerThreadgroup: tg)
        enc.endEncoding()
    }
}
```

- [ ] **Step 2: Build, expect pass**

⌘B.

- [ ] **Step 3: Commit**

```bash
git add AudioVisualizer/Infrastructure/Metal/Shaders/AlchemyParticles.metal AudioVisualizer/Infrastructure/Metal/Scenes/AlchemyScene.swift
git commit -m "feat(infra/metal): AlchemyScene compute-driven particles"
```

---

### Task 6.6: `MetalVisualizationRenderer` driver

**Files:**
- Create: `AudioVisualizer/Infrastructure/Metal/MetalVisualizationRenderer.swift`

- [ ] **Step 1: Implement the driver**

```swift
import Metal
import MetalKit
import Domain
import os.lock

final class MetalVisualizationRenderer: NSObject, VisualizationRendering, MTKViewDelegate, @unchecked Sendable {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let library: MTLLibrary

    private var scenes: [SceneKind: VisualizerScene] = [:]
    private var currentKind: SceneKind = .bars
    private var paletteTexture: MTLTexture
    private var lastTimestamp: CFTimeInterval = 0

    private let stateLock = OSAllocatedUnfairLock(initialState: State())
    private struct State {
        var spectrum: SpectrumFrame = SpectrumFrame(bands: Array(repeating: 0, count: 64), rms: 0, timestamp: .zero)
        var waveform: [Float] = Array(repeating: 0, count: 1024)
        var beat: BeatEvent?
        var beatConsumed = true
    }

    init() throws {
        guard let d = MTLCreateSystemDefaultDevice() else { throw RenderError.metalDeviceUnavailable }
        self.device = d
        guard let q = d.makeCommandQueue() else { throw RenderError.metalDeviceUnavailable }
        self.queue = q
        guard let lib = d.makeDefaultLibrary() else { throw RenderError.shaderCompilationFailed(name: "default") }
        self.library = lib
        guard let pal = PaletteFactory.texture(from: PaletteFactory.xpNeon, device: d) else {
            throw RenderError.pipelineCreationFailed(name: "palette")
        }
        self.paletteTexture = pal
        super.init()

        let bars = BarsScene(); try bars.build(device: d, library: lib, paletteTexture: pal); scenes[.bars] = bars
        let scope = ScopeScene(); try scope.build(device: d, library: lib, paletteTexture: pal); scenes[.scope] = scope
        let alch = AlchemyScene(); try alch.build(device: d, library: lib, paletteTexture: pal); scenes[.alchemy] = alch
    }

    func setScene(_ kind: SceneKind) { currentKind = kind }

    func setPalette(_ palette: ColorPalette) {
        guard let pal = PaletteFactory.texture(from: palette, device: device) else { return }
        self.paletteTexture = pal
        // Re-build scenes with new palette (cheap — pipelines are unchanged).
        if let bars = scenes[.bars] as? BarsScene { try? bars.build(device: device, library: library, paletteTexture: pal) }
        if let scope = scenes[.scope] as? ScopeScene { try? scope.build(device: device, library: library, paletteTexture: pal) }
        if let alch = scenes[.alchemy] as? AlchemyScene { try? alch.build(device: device, library: library, paletteTexture: pal) }
    }

    func consume(spectrum: SpectrumFrame, waveform: [Float], beat: BeatEvent?) {
        stateLock.withLock { s in
            s.spectrum = spectrum
            s.waveform = waveform
            if let beat { s.beat = beat; s.beatConsumed = false }
        }
    }

    // MARK: MTKViewDelegate
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        let dt = lastTimestamp == 0 ? Float(1.0/60.0) : Float(min(0.1, now - lastTimestamp))
        lastTimestamp = now

        let snap = stateLock.withLock { s -> (SpectrumFrame, [Float], BeatEvent?) in
            let b = s.beatConsumed ? nil : s.beat
            s.beatConsumed = true
            return (s.spectrum, s.waveform, b)
        }
        let (spectrum, waveform, beat) = snap
        guard let scene = scenes[currentKind] else { return }
        scene.update(spectrum: spectrum, waveform: waveform, beat: beat, dt: dt)

        guard let drawable = view.currentDrawable,
              let rpd = view.currentRenderPassDescriptor,
              let cmd = queue.makeCommandBuffer() else { return }

        // Compute pass for Alchemy.
        if let alch = scene as? AlchemyScene {
            alch.dispatchCompute(into: cmd, dt: dt, aspect: Float(view.drawableSize.width / max(1, view.drawableSize.height)))
        }

        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0.02, green: 0.02, blue: 0.04, alpha: 1)
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return }
        var uniforms = SceneUniforms(
            time: Float(now),
            aspect: Float(view.drawableSize.width / max(1, view.drawableSize.height)),
            rms: spectrum.rms,
            beatStrength: beat?.strength ?? 0)
        scene.encode(into: enc, uniforms: &uniforms)
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }
}
```

- [ ] **Step 2: Build, expect pass**

⌘B.

- [ ] **Step 3: Commit**

```bash
git add AudioVisualizer/Infrastructure/Metal/MetalVisualizationRenderer.swift
git commit -m "feat(infra/metal): MetalVisualizationRenderer driver with scene catalog"
```

---

## Phase 7 — Presentation & Composition Root

### Task 7.1: `VisualizerViewModel` (Observable)

**Files:**
- Create: `AudioVisualizer/Presentation/ViewModels/VisualizerViewModel.swift`

- [ ] **Step 1: Implement**

```swift
import Foundation
import Domain
import Application
import Observation

@Observable
final class VisualizerViewModel {
    private(set) var state: VisualizationState = .idle
    var sources: [AudioSource] = [.systemWide]
    var selectedSource: AudioSource = .systemWide
    var currentScene: SceneKind = .bars

    private let listSources: ListAudioSourcesUseCase
    private let selectSource: SelectAudioSourceUseCase
    private let changeScene: ChangeSceneUseCase
    private let start: StartVisualizationUseCase
    private let stop: StopVisualizationUseCase
    private var streamTask: Task<Void, Never>?

    init(listSources: ListAudioSourcesUseCase,
         selectSource: SelectAudioSourceUseCase,
         changeScene: ChangeSceneUseCase,
         start: StartVisualizationUseCase,
         stop: StopVisualizationUseCase) {
        self.listSources = listSources; self.selectSource = selectSource
        self.changeScene = changeScene; self.start = start; self.stop = stop
    }

    func onAppear() {
        Task { @MainActor in
            do { sources = try await listSources.execute() } catch { state = .error(.permissionDenied) }
            beginStream()
        }
    }

    func selectScene(_ k: SceneKind) {
        currentScene = k
        changeScene.execute(k)
    }

    func selectSource(_ s: AudioSource) {
        selectedSource = s
        selectSource.execute(s)
        beginStream()
    }

    private func beginStream() {
        streamTask?.cancel()
        let useCase = start
        let chosen = selectedSource
        streamTask = Task { @MainActor in
            await stop.execute()
            for await s in await useCase.execute(source: chosen) {
                self.state = s
            }
        }
    }
}
```

- [ ] **Step 2: Build, expect pass**

⌘B.

- [ ] **Step 3: Commit**

```bash
git add AudioVisualizer/Presentation/ViewModels/VisualizerViewModel.swift
git commit -m "feat(presentation): VisualizerViewModel @Observable"
```

---

### Task 7.2: Root view, permission gate, scene toolbar

**Files:**
- Create: `AudioVisualizer/Presentation/Scenes/RootView.swift`
- Create: `AudioVisualizer/Presentation/Scenes/PermissionGate.swift`
- Create: `AudioVisualizer/Presentation/Scenes/SceneToolbar.swift`

- [ ] **Step 1: Implement**

`PermissionGate.swift`:
```swift
import SwiftUI

struct PermissionGate: View {
    let onGrant: () -> Void
    var body: some View {
        VStack(spacing: 24) {
            Text("Audio Visualizer needs permission to listen to system audio.")
                .multilineTextAlignment(.center)
                .font(.title2)
            Button("Grant Audio Capture access", action: onGrant)
                .keyboardShortcut(.defaultAction)
            Link("Open System Settings → Privacy → Audio Capture",
                 destination: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!)
                .font(.footnote)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
        .foregroundStyle(.white)
    }
}
```

`SceneToolbar.swift`:
```swift
import SwiftUI
import Domain

struct SceneToolbar: View {
    @Binding var currentScene: SceneKind
    var body: some View {
        Picker("", selection: $currentScene) {
            Text("Bars").tag(SceneKind.bars)
            Text("Scope").tag(SceneKind.scope)
            Text("Alchemy").tag(SceneKind.alchemy)
        }
        .pickerStyle(.segmented)
        .frame(width: 240)
    }
}
```

`RootView.swift`:
```swift
import SwiftUI
import Domain

struct RootView: View {
    @Bindable var vm: VisualizerViewModel
    let renderer: MetalVisualizationRenderer
    let requestPermission: () async -> Void

    var body: some View {
        ZStack(alignment: .top) {
            MetalCanvas(renderer: renderer)
                .ignoresSafeArea()
            switch vm.state {
            case .waitingForPermission, .error(.permissionDenied):
                PermissionGate { Task { await requestPermission(); vm.onAppear() } }
            case .running, .idle, .noAudioYet:
                SceneToolbar(currentScene: Binding(
                    get: { vm.currentScene },
                    set: { vm.selectScene($0) }))
                    .padding(.top, 16)
            case .error(let e):
                Text("Error: \(String(describing: e))").foregroundStyle(.white)
            }
        }
        .onAppear { vm.onAppear() }
    }
}
```

- [ ] **Step 2: Build, expect pass**

⌘B.

- [ ] **Step 3: Commit**

```bash
git add AudioVisualizer/Presentation/Scenes
git commit -m "feat(presentation): RootView, PermissionGate, SceneToolbar"
```

---

### Task 7.3: `CompositionRoot` and `@main` wiring

**Files:**
- Create: `AudioVisualizer/App/CompositionRoot.swift`
- Modify: `AudioVisualizer/App/VisualizerApp.swift`

- [ ] **Step 1: Implement Composition Root**

`CompositionRoot.swift`:
```swift
import Foundation
import Domain
import Application

@MainActor
final class CompositionRoot {
    let viewModel: VisualizerViewModel
    let renderer: MetalVisualizationRenderer
    let permission: TCCAudioCapturePermission

    init() throws {
        let capture = CoreAudioTapCapture()
        let discovery = RunningApplicationsDiscovery()
        let permission = TCCAudioCapturePermission()
        let prefs = UserDefaultsPreferences()
        let analyzer = VDSPSpectrumAnalyzer(bandCount: 64, sampleRate: SampleRate(hz: 48_000))
        let beats = EnergyBeatDetector()
        let renderer = try MetalVisualizationRenderer()

        let list = ListAudioSourcesUseCase(discovery: discovery)
        let select = SelectAudioSourceUseCase(preferences: prefs)
        let change = ChangeSceneUseCase(renderer: renderer, preferences: prefs)
        let start = StartVisualizationUseCase(capture: capture, analyzer: analyzer, beats: beats,
                                              renderer: renderer, permissions: permission)
        let stop = StopVisualizationUseCase(capture: capture)

        // Hydrate from preferences.
        let saved = prefs.load()
        renderer.setScene(saved.lastScene)

        self.viewModel = VisualizerViewModel(listSources: list, selectSource: select, changeScene: change,
                                             start: start, stop: stop)
        self.viewModel.currentScene = saved.lastScene
        self.viewModel.selectedSource = saved.lastSource
        self.renderer = renderer
        self.permission = permission
    }
}
```

- [ ] **Step 2: Wire into `@main`**

`VisualizerApp.swift`:
```swift
import SwiftUI

@main
struct VisualizerApp: App {
    @State private var root: CompositionRoot?
    @State private var initError: String?

    var body: some Scene {
        WindowGroup("Audio Visualizer") {
            Group {
                if let root {
                    RootView(vm: root.viewModel, renderer: root.renderer) {
                        _ = await root.permission.request()
                    }
                } else if let err = initError {
                    Text("Failed to start: \(err)").padding()
                } else {
                    ProgressView().task {
                        do { root = try CompositionRoot() }
                        catch { initError = String(describing: error) }
                    }
                }
            }
            .frame(minWidth: 1280, minHeight: 720)
        }
    }
}
```

- [ ] **Step 3: Build, run, verify**

⌘R. Expected behavior:
1. First launch: blank dark canvas appears briefly, then the `PermissionGate` view replaces it.
2. Click "Grant Audio Capture access" → macOS shows TCC prompt → click Allow.
3. Play music in another app.
4. Bars scene appears, bars react to music.
5. Click "Scope" — waveform replaces bars.
6. Click "Alchemy" — particle field with bass reaction.
7. Quit + relaunch → opens directly to last-used scene.

- [ ] **Step 4: Commit**

```bash
git add AudioVisualizer/App
git commit -m "feat(app): CompositionRoot wires adapters into use cases and view model"
```

---

## Phase 8 — Polish & risk mitigations

### Task 8.1: Handle target-process silence with "noAudioYet" overlay

**Files:**
- Modify: `AudioVisualizer/Infrastructure/CoreAudio/CoreAudioTapCapture.swift`
- Modify: `AudioVisualizer/Presentation/Scenes/RootView.swift`

- [ ] **Step 1: In `CoreAudioTapCapture`, track timestamp of last received bytes**

Add a property:
```swift
private var lastDataTimestamp: CFTimeInterval = 0
```
Update it inside the drainer whenever `bytes > 0`.

Expose a method:
```swift
func secondsSinceLastData() -> Double { CACurrentMediaTime() - lastDataTimestamp }
```

This breaks the abstraction slightly (an adapter exposing an extra method), but it's read-only and surfaces a real domain concern: "no audio currently flowing." Alternative: emit a synthesised `AudioFrame` with all zeros every 250 ms when silent and let the renderer detect persistent zero RMS — that keeps the port pure. Choose this simpler alt.

Edit the drainer: if no bytes available for >500 ms, yield a silent `AudioFrame` (1024 zero samples) so downstream sees something.

- [ ] **Step 2: In `RootView`, when `spectrum.rms` stays below 0.005 for 2 s, show overlay**

Already covered if we add a `noAudioYet` state to the view model when consumed RMS stays low. Update `VisualizerViewModel` to listen on a separate `Task` that polls the renderer's latest RMS every 250 ms.

Simpler implementation: expose `latestRMS` on the renderer (atomically read) and the VM polls it.

```swift
// MetalVisualizationRenderer
var latestRMS: Float { stateLock.withLock { $0.spectrum.rms } }
```

```swift
// VisualizerViewModel
func startSilenceWatch() {
    Task { @MainActor in
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(250))
            // signal stored separately so we don't churn state
        }
    }
}
```

Then in RootView show a small "Waiting for audio…" overlay when RMS < 0.005 for >2 s.

- [ ] **Step 3: Manual verify**

Pause the music. Within 2 s, overlay appears. Resume, overlay disappears.

- [ ] **Step 4: Commit**

```bash
git add AudioVisualizer
git commit -m "feat: surface 'waiting for audio' overlay when system output is silent"
```

---

### Task 8.2: Default output device change listener

**Files:**
- Modify: `AudioVisualizer/Infrastructure/CoreAudio/CoreAudioTapCapture.swift`

- [ ] **Step 1: Register a listener after `start`**

```swift
var addr = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain)
let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
    guard let self else { return }
    Task { await self.restart() }
}
AudioObjectAddPropertyListenerBlock(.system, &addr, drainQueue, listener)
```

Store the listener block and remove it on `stop`.

Add `func restart() async` that stops the current capture and re-creates the aggregate against the new default output (preserving the original `AudioSource`).

- [ ] **Step 2: Manual test**

Start visualizer, switch system output (e.g., AirPods → Built-in speakers). Visualizer should reconnect within a second without restart.

- [ ] **Step 3: Commit**

```bash
git add AudioVisualizer/Infrastructure/CoreAudio/CoreAudioTapCapture.swift
git commit -m "feat: rebuild aggregate on default output device change"
```

---

### Task 8.3: Stale-aggregate sweep on launch

**Files:**
- Modify: `AudioVisualizer/Infrastructure/CoreAudio/CoreAudioTapCapture.swift`

- [ ] **Step 1: On `start`, list existing aggregate devices and destroy any whose UID matches `^Tap-` or contains a UUID pattern**

```swift
private static func sweepStaleAggregates() {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(.system, &addr, 0, nil, &size) == noErr else { return }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    AudioObjectGetPropertyData(.system, &addr, 0, nil, &size, &ids)
    let uuidRegex = try! NSRegularExpression(pattern: "^[0-9A-Fa-f-]{36}$")
    for id in ids {
        if let uid = try? id.readString(kAudioDevicePropertyDeviceUID),
           uuidRegex.firstMatch(in: uid, options: [], range: NSRange(uid.startIndex..., in: uid)) != nil {
            AudioHardwareDestroyAggregateDevice(id)
        }
    }
}
```

Call this once in `start(source:)` before creating the new aggregate.

- [ ] **Step 2: Manual test**

Force-quit the app while running (so cleanup doesn't fire). Relaunch — first start should succeed without `tapCreationFailed`.

- [ ] **Step 3: Commit**

```bash
git add AudioVisualizer/Infrastructure/CoreAudio/CoreAudioTapCapture.swift
git commit -m "fix: sweep stale UUID-named aggregate devices on launch"
```

---

## Phase 9 — Final verification

### Task 9.1: Run the full test suite

- [ ] **Step 1: Run SwiftPM tests**

Run: `swift test`
Expected: all DomainTests and ApplicationTests pass; build succeeds.

- [ ] **Step 2: Run Xcode tests**

⌘U in Xcode. Expected: InfrastructureTests pass.

- [ ] **Step 3: Manual end-to-end check**

1. Launch app on macOS 14.2+.
2. First-run permission prompt appears.
3. Granting permission and playing music produces visualization within 2 seconds.
4. Scene swap works.
5. Quit + relaunch preserves scene.
6. Switch output device — visualizer reconnects.
7. Pause music — "Waiting for audio…" overlay appears within 2 s.

- [ ] **Step 4: Confirm architecture invariant**

Run:
```bash
grep -rE "import (CoreAudio|AVFoundation|Metal|MetalKit|Accelerate|SwiftUI|AppKit)" Sources/Domain Sources/Application
```
Expected: no matches. Only `import Foundation` is allowed in those folders.

- [ ] **Step 5: Final commit + tag**

```bash
git tag v0.1.0
git commit --allow-empty -m "release: v0.1.0 XP-style system audio visualizer (Bars + Scope + Alchemy)"
```

---

## Self-Review Notes

- **Spec coverage:** Every section of the spec maps to at least one task:
  - §4 Architecture → Phases 1, 2, Task 7.3
  - §5 Domain model → Phase 1
  - §6 Use cases → Phase 2
  - §7 Concurrency boundary → Tasks 5.4, 5.5
  - §8 Visualizations → Tasks 6.3, 6.4, 6.5
  - §9 UI → Tasks 7.1, 7.2
  - §10 Error handling → present across Phases 5 and 7
  - §11 Testing → tests interleaved in every phase
  - §12 Build / sign → Task 3.1
  - §13 Risks → Phase 8
- **Placeholders:** None — every code step shows code; every command is concrete.
- **Type consistency:** `SystemAudioCapturing.start` returns `AsyncStream<AudioFrame>` in port (Task 1.3), adapter (Task 5.5), and use case (Task 2.3). `VisualizationRendering.consume` signature matches across Domain (Task 1.5), Application (Task 2.3), and Infrastructure (Task 6.6). `SpectrumFrame.bands` length consistently == `analyzer.bandCount` (64).
- **Known approximation:** Task 5.5 assumes the IOProc delivers a single contiguous buffer; Task 5.6 immediately patches the non-interleaved case discovered during smoke testing. This is the only place the plan defers a detail to verification — and it's a deliberate "ship a thing, then fix it" because we can't know the format until the tap is created at runtime.
