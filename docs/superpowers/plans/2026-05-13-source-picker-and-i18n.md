# Source Picker + i18n Implementation Plan (v0.2)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Add (1) audio source picker UI exposing the existing `ListAudioSourcesUseCase`, and (2) runtime language switching (English + Spanish + System default) via Clean Architecture, accessible from a Settings sheet.

**Architecture:** Same Clean+DDD layering as v0.1. New `Localization` bounded context in Domain with one port (`Localizing`) and one adapter (`BundleLocalizer`). User-facing strings catalogued as `L10nKey` enum cases keyed against a single Xcode String Catalog (`.xcstrings`). Live switching via `@Observable` localizer; SwiftUI views read strings through it.

**Tech Stack:** Swift 5.10, SwiftUI `@Observable`, Xcode 15 String Catalog (`.xcstrings`), Foundation `NSLocalizedString` + `Bundle(path:)`, existing test infrastructure (XCTest + SwiftPM).

**Spec:** [`docs/superpowers/specs/2026-05-13-source-picker-and-i18n-design.md`](../specs/2026-05-13-source-picker-and-i18n-design.md)

**Parent state:** Commit `ddb54b4` (v0.1.0). 25 tests pass.

---

## Phase 1 — Domain extensions

### Task 1.1: `Language` value object

**Files:**
- Create: `Sources/Domain/Localization/ValueObjects/Language.swift`
- Create: `Tests/DomainTests/Localization/LanguageTests.swift`

- [ ] **Step 1: Write the failing test**

`Tests/DomainTests/Localization/LanguageTests.swift`:
```swift
import XCTest
@testable import Domain

final class LanguageTests: XCTestCase {
    func test_raw_value_round_trip() {
        for lang in Language.allCases {
            XCTAssertEqual(Language(rawValue: lang.rawValue), lang)
        }
    }
    func test_all_three_cases_present() {
        XCTAssertEqual(Set(Language.allCases), [.system, .en, .es])
    }
    func test_display_names_are_nonempty() {
        for lang in Language.allCases {
            XCTAssertFalse(lang.displayName.isEmpty)
        }
    }
}
```

- [ ] **Step 2: Run, expect failure**

Run: `swift test --filter DomainTests.LanguageTests`
Expected: type not defined.

- [ ] **Step 3: Implement**

`Sources/Domain/Localization/ValueObjects/Language.swift`:
```swift
public enum Language: String, CaseIterable, Sendable, Equatable {
    case system, en, es

    public var displayName: String {
        switch self {
        case .system: return "System default"
        case .en:     return "English"
        case .es:     return "Español"
        }
    }
}
```

- [ ] **Step 4: Run, expect pass**

Run: `swift test --filter DomainTests`
Expected: all pass (existing + 3 new).

- [ ] **Step 5: Commit**

```bash
git add Sources/Domain/Localization Tests/DomainTests/Localization/LanguageTests.swift
git commit -m "feat(domain): add Language value object"
```

---

### Task 1.2: `L10nKey` enum

**Files:**
- Create: `Sources/Domain/Localization/ValueObjects/L10nKey.swift`
- Create: `Tests/DomainTests/Localization/L10nKeyTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Domain

final class L10nKeyTests: XCTestCase {
    func test_raw_values_unique_and_nonempty() {
        let raws = L10nKey.allCases.map(\.rawValue)
        XCTAssertEqual(raws.count, Set(raws).count, "duplicate L10nKey rawValues")
        for r in raws { XCTAssertFalse(r.isEmpty) }
    }
    func test_known_keys_present() {
        XCTAssertEqual(L10nKey.sourceLabel.rawValue, "toolbar.source.label")
        XCTAssertEqual(L10nKey.waitingForAudio.rawValue, "overlay.waitingForAudio")
        XCTAssertEqual(L10nKey.settingsLanguageLabel.rawValue, "settings.language.label")
    }
}
```

- [ ] **Step 2: Run, expect failure**

`swift test --filter DomainTests.L10nKeyTests`

- [ ] **Step 3: Implement**

`Sources/Domain/Localization/ValueObjects/L10nKey.swift`:
```swift
public enum L10nKey: String, CaseIterable, Sendable {
    // Toolbar
    case sourceLabel              = "toolbar.source.label"
    case sourceSystemWide         = "toolbar.source.systemWide"
    case sceneBars                = "toolbar.scene.bars"
    case sceneScope               = "toolbar.scene.scope"
    case sceneAlchemy             = "toolbar.scene.alchemy"
    case settingsButton           = "toolbar.settings.button"

    // Permission gate
    case permissionTitle          = "permission.title"
    case permissionGrant          = "permission.grant"
    case permissionOpenSettings   = "permission.openSettings"

    // Overlay
    case waitingForAudio          = "overlay.waitingForAudio"
    case errorPrefix              = "overlay.errorPrefix"

    // Settings
    case settingsTitle            = "settings.title"
    case settingsLanguageLabel    = "settings.language.label"
    case settingsClose            = "settings.close"

    // Languages displayed in settings picker (override defaults from Language.displayName for localization)
    case languageSystem           = "language.system"
    case languageEnglish          = "language.english"
    case languageSpanish          = "language.spanish"
}
```

- [ ] **Step 4: Pass**

`swift test --filter DomainTests`

- [ ] **Step 5: Commit**

```bash
git add Sources/Domain/Localization/ValueObjects/L10nKey.swift Tests/DomainTests/Localization/L10nKeyTests.swift
git commit -m "feat(domain): add L10nKey enum cataloging user-facing strings"
```

---

### Task 1.3: `Localizing` port

**Files:**
- Create: `Sources/Domain/Localization/Ports/Localizing.swift`

- [ ] **Step 1: Implement**

```swift
public protocol Localizing: AnyObject, Sendable {
    func string(_ key: L10nKey) -> String
    func setLanguage(_ lang: Language)
    var current: Language { get }
    var resolvedLocale: String { get }
}
```

- [ ] **Step 2: Build**

`swift build`. Expected: success.

- [ ] **Step 3: Commit**

```bash
git add Sources/Domain/Localization/Ports/Localizing.swift
git commit -m "feat(domain): add Localizing port"
```

---

### Task 1.4: Extend `UserPreferences` with `lastLanguage`

**Files:**
- Modify: `Sources/Domain/Preferences/ValueObjects/UserPreferences.swift`
- Modify: `Tests/DomainTests/Preferences/UserPreferencesTests.swift`

- [ ] **Step 1: Update tests first**

Replace `Tests/DomainTests/Preferences/UserPreferencesTests.swift`:
```swift
import XCTest
@testable import Domain

final class UserPreferencesTests: XCTestCase {
    func test_defaults() {
        let p = UserPreferences.default
        XCTAssertEqual(p.lastScene, .bars)
        XCTAssertEqual(p.lastSource, .systemWide)
        XCTAssertEqual(p.lastPaletteName, "XP Neon")
        XCTAssertEqual(p.lastLanguage, .system)
    }
    func test_init_holds_all_fields() {
        let p = UserPreferences(lastSource: .process(pid: 1, bundleID: "x"),
                                lastScene: .alchemy,
                                lastPaletteName: "Aurora",
                                lastLanguage: .es)
        XCTAssertEqual(p.lastLanguage, .es)
        XCTAssertEqual(p.lastScene, .alchemy)
    }
}
```

- [ ] **Step 2: Run, expect failure**

`swift test --filter DomainTests.UserPreferencesTests`
Expected: `lastLanguage` not a member.

- [ ] **Step 3: Update implementation**

Replace `Sources/Domain/Preferences/ValueObjects/UserPreferences.swift`:
```swift
public struct UserPreferences: Equatable, Sendable {
    public var lastSource: AudioSource
    public var lastScene: SceneKind
    public var lastPaletteName: String
    public var lastLanguage: Language
    public init(lastSource: AudioSource,
                lastScene: SceneKind,
                lastPaletteName: String,
                lastLanguage: Language) {
        self.lastSource = lastSource
        self.lastScene = lastScene
        self.lastPaletteName = lastPaletteName
        self.lastLanguage = lastLanguage
    }
    public static let `default` = UserPreferences(
        lastSource: .systemWide,
        lastScene: .bars,
        lastPaletteName: "XP Neon",
        lastLanguage: .system)
}
```

- [ ] **Step 4: Run, expect pass**

`swift test --filter DomainTests`

- [ ] **Step 5: Commit**

```bash
git add Sources/Domain/Preferences/ValueObjects/UserPreferences.swift Tests/DomainTests/Preferences/UserPreferencesTests.swift
git commit -m "feat(domain): extend UserPreferences with lastLanguage"
```

---

## Phase 2 — Application

### Task 2.1: `ChangeLanguageUseCase`

**Files:**
- Create: `Sources/Application/UseCases/ChangeLanguageUseCase.swift`
- Create: `Tests/ApplicationTests/Fakes/FakeLocalizing.swift`
- Create: `Tests/ApplicationTests/UseCases/ChangeLanguageUseCaseTests.swift`

- [ ] **Step 1: Write failing test**

`Tests/ApplicationTests/Fakes/FakeLocalizing.swift`:
```swift
import Domain

final class FakeLocalizing: Localizing, @unchecked Sendable {
    var current: Language = .system
    var resolvedLocale: String = "en"
    private(set) var stringCalls: [L10nKey] = []
    private(set) var setLanguageCalls: [Language] = []
    func string(_ key: L10nKey) -> String { stringCalls.append(key); return key.rawValue }
    func setLanguage(_ lang: Language) { setLanguageCalls.append(lang); current = lang }
}
```

`Tests/ApplicationTests/UseCases/ChangeLanguageUseCaseTests.swift`:
```swift
import XCTest
@testable import Application
@testable import Domain

final class ChangeLanguageUseCaseTests: XCTestCase {
    func test_sets_language_on_localizer_and_persists() {
        let loc = FakeLocalizing()
        let prefs = FakePreferencesStoring()
        let sut = ChangeLanguageUseCase(localizer: loc, preferences: prefs)
        sut.execute(.es)
        XCTAssertEqual(loc.setLanguageCalls, [.es])
        XCTAssertEqual(prefs.stored.lastLanguage, .es)
    }
}
```

NOTE: `FakePreferencesStoring` was created in v0.1 and starts with `.default` which now defaults `lastLanguage = .system`. The test must verify it changes to `.es`.

- [ ] **Step 2: Run, expect failure**

`swift test --filter ApplicationTests.ChangeLanguageUseCaseTests`

- [ ] **Step 3: Implement**

`Sources/Application/UseCases/ChangeLanguageUseCase.swift`:
```swift
import Domain

public struct ChangeLanguageUseCase: Sendable {
    private let localizer: Localizing
    private let preferences: PreferencesStoring
    public init(localizer: Localizing, preferences: PreferencesStoring) {
        self.localizer = localizer
        self.preferences = preferences
    }
    public func execute(_ lang: Language) {
        localizer.setLanguage(lang)
        var p = preferences.load()
        p.lastLanguage = lang
        preferences.save(p)
    }
}
```

- [ ] **Step 4: Run, expect pass**

`swift test --filter ApplicationTests`

- [ ] **Step 5: Commit**

```bash
git add Sources/Application/UseCases/ChangeLanguageUseCase.swift \
        Tests/ApplicationTests/Fakes/FakeLocalizing.swift \
        Tests/ApplicationTests/UseCases/ChangeLanguageUseCaseTests.swift
git commit -m "feat(application): add ChangeLanguageUseCase"
```

---

## Phase 3 — Infrastructure

### Task 3.1: Update `UserDefaultsPreferences` DTO to round-trip `lastLanguage`

**Files:**
- Modify: `AudioVisualizer/Infrastructure/Persistence/UserDefaultsPreferences.swift`
- Modify: `AudioVisualizer/Tests/Infrastructure/UserDefaultsPreferencesTests.swift`

- [ ] **Step 1: Update the test**

Add a new test to `UserDefaultsPreferencesTests.swift`:
```swift
func test_round_trip_includes_language() {
    let suite = "test.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let sut = UserDefaultsPreferences(defaults: defaults)
    var p = sut.load()
    p.lastLanguage = .es
    sut.save(p)
    XCTAssertEqual(sut.load().lastLanguage, .es)
}
```

The existing `test_round_trip` test is also affected (the `var p = sut.load()` block needs to include `p.lastLanguage = .es` to be exhaustive), but adding the new dedicated test is cleaner.

- [ ] **Step 2: Run, expect failure**

`xcodebuild test ...`. Expected: the new test fails because the DTO ignores `lastLanguage` (or `.default` returns `.system` and we never assert the loaded value matches `.es`).

- [ ] **Step 3: Update the DTO**

Replace the `DTO` struct inside `UserDefaultsPreferences.swift`:
```swift
private struct DTO: Codable {
    let sourceKind: String
    let pid: Int32?
    let bundleID: String?
    let scene: String
    let paletteName: String
    let language: String?   // new — optional for backward compat with v0.1 stored prefs

    init(domain p: UserPreferences) {
        switch p.lastSource {
        case .systemWide: sourceKind = "systemWide"; pid = nil; bundleID = nil
        case .process(let pid, let bid): sourceKind = "process"; self.pid = pid; bundleID = bid
        }
        scene = p.lastScene.rawValue
        paletteName = p.lastPaletteName
        language = p.lastLanguage.rawValue
    }

    func toDomain() -> UserPreferences {
        let source: AudioSource = {
            if sourceKind == "process", let pid, let bundleID { return .process(pid: pid, bundleID: bundleID) }
            return .systemWide
        }()
        let scene = SceneKind(rawValue: scene) ?? .bars
        let lang = Language(rawValue: language ?? "") ?? .system
        return UserPreferences(lastSource: source, lastScene: scene, lastPaletteName: paletteName, lastLanguage: lang)
    }
}
```

- [ ] **Step 4: Run, expect pass**

`xcodebuild test ...`

- [ ] **Step 5: Commit**

```bash
git add AudioVisualizer.xcodeproj AudioVisualizer/Infrastructure/Persistence/UserDefaultsPreferences.swift AudioVisualizer/Tests/Infrastructure/UserDefaultsPreferencesTests.swift
git commit -m "feat(infra): round-trip lastLanguage in UserDefaultsPreferences"
```

---

### Task 3.2: `Localizable.xcstrings` + project.yml include

**Files:**
- Create: `AudioVisualizer/Resources/Localizable.xcstrings`
- Modify: `project.yml`
- Regenerate: `AudioVisualizer.xcodeproj`

- [ ] **Step 1: Create the String Catalog**

Create `AudioVisualizer/Resources/Localizable.xcstrings` with all keys from `L10nKey` and translations for en + es. Use this JSON literal:

```json
{
  "sourceLanguage" : "en",
  "version" : "1.0",
  "strings" : {
    "toolbar.source.label" : {
      "localizations" : {
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Source" } },
        "es" : { "stringUnit" : { "state" : "translated", "value" : "Fuente" } }
      }
    },
    "toolbar.source.systemWide" : {
      "localizations" : {
        "en" : { "stringUnit" : { "state" : "translated", "value" : "All system audio" } },
        "es" : { "stringUnit" : { "state" : "translated", "value" : "Todo el audio del sistema" } }
      }
    },
    "toolbar.scene.bars" : {
      "localizations" : {
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Bars" } },
        "es" : { "stringUnit" : { "state" : "translated", "value" : "Barras" } }
      }
    },
    "toolbar.scene.scope" : {
      "localizations" : {
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Scope" } },
        "es" : { "stringUnit" : { "state" : "translated", "value" : "Osciloscopio" } }
      }
    },
    "toolbar.scene.alchemy" : {
      "localizations" : {
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Alchemy" } },
        "es" : { "stringUnit" : { "state" : "translated", "value" : "Alquimia" } }
      }
    },
    "toolbar.settings.button" : {
      "localizations" : {
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Settings" } },
        "es" : { "stringUnit" : { "state" : "translated", "value" : "Ajustes" } }
      }
    },
    "permission.title" : {
      "localizations" : {
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Audio Visualizer needs permission to listen to system audio." } },
        "es" : { "stringUnit" : { "state" : "translated", "value" : "El Visualizador de Audio necesita permiso para escuchar el audio del sistema." } }
      }
    },
    "permission.grant" : {
      "localizations" : {
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Grant Audio Capture access" } },
        "es" : { "stringUnit" : { "state" : "translated", "value" : "Conceder acceso de captura de audio" } }
      }
    },
    "permission.openSettings" : {
      "localizations" : {
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Open System Settings → Privacy → Audio Capture" } },
        "es" : { "stringUnit" : { "state" : "translated", "value" : "Abrir Ajustes del Sistema → Privacidad → Captura de audio" } }
      }
    },
    "overlay.waitingForAudio" : {
      "localizations" : {
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Waiting for audio…" } },
        "es" : { "stringUnit" : { "state" : "translated", "value" : "Esperando audio…" } }
      }
    },
    "overlay.errorPrefix" : {
      "localizations" : {
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Error: " } },
        "es" : { "stringUnit" : { "state" : "translated", "value" : "Error: " } }
      }
    },
    "settings.title" : {
      "localizations" : {
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Settings" } },
        "es" : { "stringUnit" : { "state" : "translated", "value" : "Ajustes" } }
      }
    },
    "settings.language.label" : {
      "localizations" : {
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Language" } },
        "es" : { "stringUnit" : { "state" : "translated", "value" : "Idioma" } }
      }
    },
    "settings.close" : {
      "localizations" : {
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Done" } },
        "es" : { "stringUnit" : { "state" : "translated", "value" : "Listo" } }
      }
    },
    "language.system" : {
      "localizations" : {
        "en" : { "stringUnit" : { "state" : "translated", "value" : "System default" } },
        "es" : { "stringUnit" : { "state" : "translated", "value" : "Predeterminado del sistema" } }
      }
    },
    "language.english" : {
      "localizations" : {
        "en" : { "stringUnit" : { "state" : "translated", "value" : "English" } },
        "es" : { "stringUnit" : { "state" : "translated", "value" : "Inglés" } }
      }
    },
    "language.spanish" : {
      "localizations" : {
        "en" : { "stringUnit" : { "state" : "translated", "value" : "Spanish" } },
        "es" : { "stringUnit" : { "state" : "translated", "value" : "Español" } }
      }
    }
  }
}
```

- [ ] **Step 2: Add the resource and `knownRegions` to `project.yml`**

The xcstrings file is in `AudioVisualizer/Resources/` — already included by the existing `sources: - path: AudioVisualizer` rule. Verify by inspecting `project.yml`. Add `knownRegions` to the target's settings so Xcode knows about both locales:

In `project.yml`, under the `AudioVisualizer` target settings:
```yaml
settings:
  base:
    # ... existing settings ...
    CFBundleAllowMixedLocalizations: YES
    DEVELOPMENT_LANGUAGE: en
```

And at the project level:
```yaml
options:
  # ... existing options ...
  developmentLanguage: en
```

Note: XcodeGen's `developmentLanguage` and explicit `knownRegions: [en, es]` may need to be added. Inspect the generated `project.pbxproj` after regenerating to confirm both `en` and `es` appear in `knownRegions`. If not, add `knownRegions: [en, es]` under `options:`.

- [ ] **Step 3: Regenerate the Xcode project and build**

```bash
xcodegen generate
xcodebuild -project AudioVisualizer.xcodeproj -scheme AudioVisualizer -destination 'platform=macOS' build 2>&1 | tail -10
```
Expected: `** BUILD SUCCEEDED **`. Look for `CompileXCStrings ...Localizable.xcstrings` in the build log — that confirms Xcode processed the catalog.

If `knownRegions` isn't picking up `es`, check the generated pbxproj for the `knownRegions` array and amend `project.yml` accordingly.

- [ ] **Step 4: Verify the compiled `.app` has the locale resources**

```bash
APP=$(find ~/Library/Developer/Xcode/DerivedData -name "AudioVisualizer.app" -type d | head -1)
ls "$APP/Contents/Resources/" | grep lproj
```
Expected: `en.lproj` AND `es.lproj` directories exist.

- [ ] **Step 5: Commit**

```bash
git add AudioVisualizer/Resources/Localizable.xcstrings project.yml AudioVisualizer.xcodeproj
git commit -m "feat(resources): Localizable.xcstrings with en+es catalog"
```

---

### Task 3.3: `BundleLocalizer` adapter

**Files:**
- Create: `AudioVisualizer/Infrastructure/Localization/BundleLocalizer.swift`
- Create: `AudioVisualizer/Tests/Infrastructure/BundleLocalizerTests.swift`

- [ ] **Step 1: Write failing test**

```swift
import XCTest
import Domain
@testable import AudioVisualizer

final class BundleLocalizerTests: XCTestCase {
    func test_english_returns_english_strings() {
        let sut = BundleLocalizer(initialLanguage: .en)
        XCTAssertEqual(sut.string(.sceneBars), "Bars")
        XCTAssertEqual(sut.string(.toolbarSourceLabel /* placeholder check */), "Source")
        XCTAssertEqual(sut.current, .en)
    }
    func test_spanish_returns_spanish_strings() {
        let sut = BundleLocalizer(initialLanguage: .es)
        XCTAssertEqual(sut.string(.sceneBars), "Barras")
        XCTAssertEqual(sut.string(.waitingForAudio), "Esperando audio…")
        XCTAssertEqual(sut.current, .es)
    }
    func test_setLanguage_changes_resolved_strings() {
        let sut = BundleLocalizer(initialLanguage: .en)
        XCTAssertEqual(sut.string(.sceneBars), "Bars")
        sut.setLanguage(.es)
        XCTAssertEqual(sut.string(.sceneBars), "Barras")
        XCTAssertEqual(sut.current, .es)
    }
    func test_missing_key_falls_back_to_raw() {
        // Can't actually test a missing key directly without adding one — skip in favor of confirming
        // resolvedLocale is consistent.
        let sut = BundleLocalizer(initialLanguage: .en)
        XCTAssertEqual(sut.resolvedLocale, "en")
        sut.setLanguage(.es)
        XCTAssertEqual(sut.resolvedLocale, "es")
    }
}
```

(Note: the test references `.toolbarSourceLabel` only conceptually — use `.sourceLabel` which is the real case from Task 1.2.)

Corrected test (replace `.toolbarSourceLabel` with `.sourceLabel`):
```swift
XCTAssertEqual(sut.string(.sourceLabel), "Source")
```

- [ ] **Step 2: Run, expect failure**

`xcodebuild test ...` — `BundleLocalizer` not defined.

- [ ] **Step 3: Implement**

```swift
import Foundation
import Domain
import Observation

@Observable
final class BundleLocalizer: Localizing, @unchecked Sendable {
    private(set) var current: Language = .system
    private var bundle: Bundle = .main
    private var version: Int = 0   // bumps on setLanguage; ensures @Observable invalidation

    init(initialLanguage: Language) { setLanguage(initialLanguage) }

    var resolvedLocale: String {
        _ = version
        switch current {
        case .system:
            return Locale.preferredLanguages.first?.components(separatedBy: "-").first ?? "en"
        case .en: return "en"
        case .es: return "es"
        }
    }

    func setLanguage(_ lang: Language) {
        current = lang
        bundle = Self.bundleForLanguage(lang) ?? .main
        version &+= 1
    }

    func string(_ key: L10nKey) -> String {
        _ = version
        return NSLocalizedString(key.rawValue, bundle: bundle, comment: "")
    }

    private static func bundleForLanguage(_ lang: Language) -> Bundle? {
        let code: String
        switch lang {
        case .system:
            code = Locale.preferredLanguages.first?.components(separatedBy: "-").first ?? "en"
        case .en: code = "en"
        case .es: code = "es"
        }
        guard let path = Bundle.main.path(forResource: code, ofType: "lproj"),
              let b = Bundle(path: path) else { return nil }
        return b
    }
}
```

- [ ] **Step 4: Run, expect pass**

`xcodebuild test ...`. The test relies on `en.lproj` and `es.lproj` being present in the test host (`AudioVisualizer.app`). If Task 3.2 was done correctly, they are.

- [ ] **Step 5: Commit**

```bash
git add AudioVisualizer.xcodeproj AudioVisualizer/Infrastructure/Localization/BundleLocalizer.swift AudioVisualizer/Tests/Infrastructure/BundleLocalizerTests.swift
git commit -m "feat(infra): BundleLocalizer adapter with @Observable live switching"
```

---

## Phase 4 — Presentation

### Task 4.1: `SourcePicker` view + VM refresh

**Files:**
- Create: `AudioVisualizer/Presentation/Scenes/SourcePicker.swift`
- Modify: `AudioVisualizer/Presentation/ViewModels/VisualizerViewModel.swift`

- [ ] **Step 1: Extend the VM with refresh + injected localizer**

Modify `VisualizerViewModel.swift`:
- Add a `private let localizer: Localizing` stored property
- Add `localizer:` to init
- Add a `refreshTask: Task<Void, Never>?` and a `func refreshSources()` method that runs `listSources.execute()`
- In `onAppear()`, also start a 3-second polling task that calls `refreshSources()`
- Provide a `displayName(for: AudioSource) -> String` helper that returns either `localizer.string(.sourceSystemWide)` or matches the bundleID against the current `sources` list and returns the `displayName`.

Wait — `sources` is `[AudioSource]`, not `[AudioProcessInfo]`. We lose the display name when converting. Solution: change the VM to also store `[AudioProcessInfo]` separately:
- Add `var processInfos: [AudioProcessInfo] = []`
- `refreshSources` populates BOTH `sources` and `processInfos`
- `displayName(for: AudioSource)` looks up the bundleID in `processInfos`

OR simpler: change `ListAudioSourcesUseCase` to return `[(AudioSource, String)]` (source + label). That's a Domain-level change. Simpler still: extend `AudioSource` with a display-name property? No, AudioSource is process-agnostic.

**Decision:** add a second VM field `processInfos: [AudioProcessInfo]`, populated by a new helper that runs `ProcessDiscovering.listAudioProcesses()` directly. Inject `ProcessDiscovering` into the VM via a new use case `ListAudioProcessesUseCase` (or just inject the port directly — Domain port injection into VM is acceptable in Clean Architecture as long as you treat the VM as the "presenter" layer).

For YAGNI, inject the port. Add `ProcessDiscovering` as a VM init param.

Concrete edits to `VisualizerViewModel.swift`:

```swift
import Foundation
import Domain
import Application
import Observation

@Observable
final class VisualizerViewModel {
    private(set) var state: VisualizationState = .idle
    var sources: [AudioSource] = [.systemWide]
    var processInfos: [AudioProcessInfo] = []
    var selectedSource: AudioSource = .systemWide
    var currentScene: SceneKind = .bars

    let localizer: Localizing                  // public so views can read

    private let listSources: ListAudioSourcesUseCase
    private let selectSourceUseCase: SelectAudioSourceUseCase
    private let changeScene: ChangeSceneUseCase
    private let start: StartVisualizationUseCase
    private let stop: StopVisualizationUseCase
    private let discovery: ProcessDiscovering
    private let renderer: MetalVisualizationRenderer
    private var streamTask: Task<Void, Never>?
    private var silenceTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private(set) var isSilent: Bool = false

    init(listSources: ListAudioSourcesUseCase,
         selectSource: SelectAudioSourceUseCase,
         changeScene: ChangeSceneUseCase,
         start: StartVisualizationUseCase,
         stop: StopVisualizationUseCase,
         discovery: ProcessDiscovering,
         renderer: MetalVisualizationRenderer,
         localizer: Localizing) {
        self.listSources = listSources
        self.selectSourceUseCase = selectSource
        self.changeScene = changeScene
        self.start = start
        self.stop = stop
        self.discovery = discovery
        self.renderer = renderer
        self.localizer = localizer
    }

    func onAppear() {
        Task { @MainActor in
            await refreshSources()
            beginStream()
            startSilenceWatch()
            startRefreshLoop()
        }
    }

    func refreshSources() async {
        do {
            sources = try await listSources.execute()
            processInfos = (try? await discovery.listAudioProcesses()) ?? []
        } catch {
            state = .error(.permissionDenied)
        }
    }

    func displayName(for source: AudioSource) -> String {
        switch source {
        case .systemWide:
            return localizer.string(.sourceSystemWide)
        case .process(_, let bundleID):
            return processInfos.first(where: { $0.bundleID == bundleID })?.displayName ?? bundleID
        }
    }

    func selectScene(_ k: SceneKind) {
        currentScene = k
        changeScene.execute(k)
    }

    func selectSource(_ s: AudioSource) {
        selectedSource = s
        selectSourceUseCase.execute(s)
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

    private func startSilenceWatch() {
        silenceTask?.cancel()
        silenceTask = Task { @MainActor [weak self] in
            var silentSinceMs: Int = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self else { return }
                let rms = self.renderer.peekRMS()
                if rms < 0.005 { silentSinceMs += 250 } else { silentSinceMs = 0 }
                self.isSilent = silentSinceMs >= 2000
            }
        }
    }

    private func startRefreshLoop() {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard let self else { return }
                await self.refreshSources()
            }
        }
    }
}
```

- [ ] **Step 2: Create `SourcePicker.swift`**

```swift
import SwiftUI
import Domain

struct SourcePicker: View {
    @Bindable var vm: VisualizerViewModel

    var body: some View {
        Picker(vm.localizer.string(.sourceLabel),
               selection: Binding(
                 get: { vm.selectedSource },
                 set: { vm.selectSource($0) })) {
            ForEach(vm.sources, id: \.self) { source in
                Text(vm.displayName(for: source)).tag(source)
            }
        }
        .pickerStyle(.menu)
        .frame(maxWidth: 220)
    }
}
```

- [ ] **Step 3: Build**

```bash
xcodegen generate
xcodebuild -project AudioVisualizer.xcodeproj -scheme AudioVisualizer -destination 'platform=macOS' build 2>&1 | tail -10
```
Expected: `** BUILD SUCCEEDED **`.

NOTE: Adding `localizer:` and `discovery:` and `renderer:` to the VM init breaks `CompositionRoot.swift`. Task 4.4 fixes that — for now, expect the CompositionRoot to not compile, which will cause a build failure. Either temporarily provide stub values in CompositionRoot or treat this as "module compiles but app target fails — fix in Task 4.4". Pick:

**Better:** Do Tasks 4.1 + 4.4 together, since the VM init signature change is what cascades. So this task may emit a partial-broken commit. Plan accordingly — fix CompositionRoot inline within this task, deferring SettingsView until Task 4.3.

Concretely: stub the `localizer` and `changeLanguage` args into CompositionRoot now (it already has `discovery` and `renderer` locally — just wire `localizer:` into the VM init and add `let localizer = BundleLocalizer(initialLanguage: saved.lastLanguage)`).

- [ ] **Step 4: Commit**

```bash
git add AudioVisualizer.xcodeproj AudioVisualizer/Presentation/ViewModels/VisualizerViewModel.swift AudioVisualizer/Presentation/Scenes/SourcePicker.swift AudioVisualizer/App/CompositionRoot.swift
git commit -m "feat(presentation): SourcePicker + VM refresh loop + localizer injection"
```

---

### Task 4.2: Localize existing views (`RootView`, `PermissionGate`, `SceneToolbar`)

**Files:**
- Modify: `AudioVisualizer/Presentation/Scenes/PermissionGate.swift`
- Modify: `AudioVisualizer/Presentation/Scenes/SceneToolbar.swift`
- Modify: `AudioVisualizer/Presentation/Scenes/RootView.swift`

- [ ] **Step 1: Update `PermissionGate.swift`**

Replace hardcoded strings with `localizer.string(...)` calls. Add `localizer: Localizing` param to the View. The view becomes:

```swift
import SwiftUI
import Domain

struct PermissionGate: View {
    let localizer: Localizing
    let onGrant: () -> Void
    var body: some View {
        VStack(spacing: 24) {
            Text(localizer.string(.permissionTitle))
                .multilineTextAlignment(.center)
                .font(.title2)
            Button(localizer.string(.permissionGrant), action: onGrant)
                .keyboardShortcut(.defaultAction)
            Link(localizer.string(.permissionOpenSettings),
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

- [ ] **Step 2: Update `SceneToolbar.swift`**

```swift
import SwiftUI
import Domain

struct SceneToolbar: View {
    let localizer: Localizing
    @Binding var currentScene: SceneKind
    var body: some View {
        Picker("", selection: $currentScene) {
            Text(localizer.string(.sceneBars)).tag(SceneKind.bars)
            Text(localizer.string(.sceneScope)).tag(SceneKind.scope)
            Text(localizer.string(.sceneAlchemy)).tag(SceneKind.alchemy)
        }
        .pickerStyle(.segmented)
        .frame(width: 240)
    }
}
```

- [ ] **Step 3: Update `RootView.swift`**

- Accept a `@Bindable var localizer: BundleLocalizer` (concrete) OR `let localizer: Localizing` (port). Concrete here is fine because the renderer is also passed as concrete.
- Pass localizer to PermissionGate and SceneToolbar.
- Replace hardcoded "Waiting for audio…" with `localizer.string(.waitingForAudio)`.
- Replace the toolbar HStack to include SourcePicker (we'll add the gear settings button in Task 4.3).

```swift
import SwiftUI
import Domain

struct RootView: View {
    @Bindable var vm: VisualizerViewModel
    let renderer: MetalVisualizationRenderer
    @Bindable var localizer: BundleLocalizer
    let requestPermission: () async -> Void
    @State private var showingSettings = false   // wired in Task 4.3

    var body: some View {
        ZStack(alignment: .top) {
            MetalCanvas(renderer: renderer)
                .ignoresSafeArea()
            switch vm.state {
            case .waitingForPermission:
                PermissionGate(localizer: localizer) {
                    Task { await requestPermission(); vm.onAppear() }
                }
            case .error(.permissionDenied):
                PermissionGate(localizer: localizer) {
                    Task { await requestPermission(); vm.onAppear() }
                }
            case .running, .idle, .noAudioYet:
                ZStack {
                    HStack(spacing: 24) {
                        // Gear button — wired in Task 4.3
                        SourcePicker(vm: vm)
                        SceneToolbar(localizer: localizer,
                                     currentScene: Binding(
                                       get: { vm.currentScene },
                                       set: { vm.selectScene($0) }))
                    }
                    .padding(.top, 16)
                    if vm.isSilent {
                        VStack {
                            Spacer()
                            Text(localizer.string(.waitingForAudio))
                                .foregroundStyle(.white.opacity(0.7))
                                .padding()
                                .background(Color.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
                            Spacer().frame(height: 80)
                        }
                    }
                }
            case .error(let e):
                Text(localizer.string(.errorPrefix) + String(describing: e))
                    .foregroundStyle(.white)
            }
        }
        .onAppear { vm.onAppear() }
    }
}
```

- [ ] **Step 4: Update `CompositionRoot.swift`**

Add `localizer` and `renderer` and `discovery` to the VM constructor (already done in Task 4.1).
Wire `localizer` into the `RootView` constructor in `VisualizerApp.swift`.

`VisualizerApp.swift`:
```swift
RootView(vm: root.viewModel,
         renderer: root.renderer,
         localizer: root.localizer) {
    _ = await root.permission.request()
}
```

Add `let localizer: BundleLocalizer` to `CompositionRoot`.

- [ ] **Step 5: Build**

```bash
xcodegen generate
xcodebuild -project AudioVisualizer.xcodeproj -scheme AudioVisualizer -destination 'platform=macOS' build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add AudioVisualizer.xcodeproj AudioVisualizer/Presentation AudioVisualizer/App
git commit -m "feat(presentation): localize PermissionGate, SceneToolbar, RootView"
```

---

### Task 4.3: `SettingsView` + gear button

**Files:**
- Create: `AudioVisualizer/Presentation/Scenes/SettingsView.swift`
- Modify: `AudioVisualizer/Presentation/Scenes/RootView.swift` (add gear button + sheet)
- Modify: `AudioVisualizer/Presentation/ViewModels/VisualizerViewModel.swift` (add `changeLanguage` use case)

- [ ] **Step 1: Update VM to accept `ChangeLanguageUseCase`**

In `VisualizerViewModel.swift`:
- Add `private let changeLanguageUseCase: ChangeLanguageUseCase`
- Add to init: `changeLanguage: ChangeLanguageUseCase`
- Expose: `func changeLanguage(_ lang: Language) { changeLanguageUseCase.execute(lang) }`

- [ ] **Step 2: Create `SettingsView.swift`**

```swift
import SwiftUI
import Domain

struct SettingsView: View {
    @Bindable var localizer: BundleLocalizer
    let onChange: (Language) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Picker(localizer.string(.settingsLanguageLabel),
                       selection: Binding(
                         get: { localizer.current },
                         set: { onChange($0) })) {
                    Text(localizer.string(.languageSystem)).tag(Language.system)
                    Text(localizer.string(.languageEnglish)).tag(Language.en)
                    Text(localizer.string(.languageSpanish)).tag(Language.es)
                }
            }
            .navigationTitle(localizer.string(.settingsTitle))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(localizer.string(.settingsClose)) { dismiss() }
                }
            }
        }
        .frame(width: 360, height: 200)
    }
}
```

- [ ] **Step 3: Add gear button + sheet to `RootView`**

Inside the `HStack` next to `SourcePicker`, prepend:
```swift
Button {
    showingSettings = true
} label: {
    Image(systemName: "gearshape")
}
.help(localizer.string(.settingsButton))
```

After the outer ZStack, add the sheet modifier:
```swift
.sheet(isPresented: $showingSettings) {
    SettingsView(localizer: localizer,
                 onChange: { lang in vm.changeLanguage(lang) })
}
```

- [ ] **Step 4: Update CompositionRoot to inject `ChangeLanguageUseCase` into the VM**

```swift
let changeLanguage = ChangeLanguageUseCase(localizer: localizer, preferences: prefs)
self.viewModel = VisualizerViewModel(
    listSources: list, selectSource: select, changeScene: change,
    start: start, stop: stop, discovery: discovery, renderer: renderer,
    localizer: localizer, changeLanguage: changeLanguage)
```

- [ ] **Step 5: Build + run a brief headless launch test**

```bash
xcodegen generate
xcodebuild -project AudioVisualizer.xcodeproj -scheme AudioVisualizer -destination 'platform=macOS' build 2>&1 | tail -5
APP=$(find ~/Library/Developer/Xcode/DerivedData -name "AudioVisualizer.app" -type d | head -1)
open "$APP"
sleep 2
pkill -f "AudioVisualizer.app/Contents/MacOS/AudioVisualizer" 2>&1 || true
```
Expected: build succeeds; app launches without immediate crash. Manual UI verification is the user's job.

- [ ] **Step 6: Commit**

```bash
git add AudioVisualizer.xcodeproj AudioVisualizer/Presentation AudioVisualizer/App
git commit -m "feat(presentation): SettingsView + language picker + gear toolbar button"
```

---

## Phase 5 — Final verification

### Task 5.1: Run all tests + tag v0.2.0

- [ ] **Step 1: SwiftPM tests**

```bash
swift test 2>&1 | tail -3
```
Expected: tests pass. Count should be ~21 (was 17 in v0.1).

- [ ] **Step 2: Xcode tests**

```bash
xcodebuild test -project AudioVisualizer.xcodeproj -scheme AudioVisualizer -destination 'platform=macOS' 2>&1 | grep "Executed [0-9]* tests" | tail -1
```
Expected: tests pass. Count should be ~12 (was 8 in v0.1).

- [ ] **Step 3: Architecture invariant check**

```bash
grep -rE "import (CoreAudio|AVFoundation|Metal|MetalKit|Accelerate|SwiftUI|AppKit)" Sources/Domain Sources/Application 2>&1
```
Expected: no output.

- [ ] **Step 4: Manual smoke test — SKIPPED** (agent can't verify language switching visually).

- [ ] **Step 5: Tag**

```bash
git tag -a v0.2.0 -m "v0.2.0 - Source picker + i18n (en+es) with live language switching

Features added on top of v0.1.0:
- Audio source picker in toolbar (live process polling every 3s)
- Settings sheet with language selector (System/English/Spanish)
- Full Clean Architecture i18n: Domain L10nKey + Language + Localizing port,
  Application ChangeLanguageUseCase, Infrastructure BundleLocalizer + xcstrings catalog

Architecture invariant: no Apple-framework imports in Domain or Application."
```

---

## Self-Review

- Every Domain type imports only Foundation: verified by grep gate.
- Every port has an adapter: `Localizing` → `BundleLocalizer`.
- New language `Language.system` falls back gracefully to en when system locale isn't en or es.
- Backward compat: existing v0.1 stored prefs (without `language` field) load to `.system` via `Language(rawValue: language ?? "") ?? .system`.
- Risks documented in spec §8 (catalog requires Xcode 15 to author but runs anywhere; Picker pop-up may not refresh while open — acceptable).
