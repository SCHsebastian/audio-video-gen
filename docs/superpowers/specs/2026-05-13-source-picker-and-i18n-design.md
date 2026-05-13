# Source Picker + i18n — Design (v0.2 amendment)

**Date:** 2026-05-13
**Status:** Draft amendment to [the v0.1 spec](2026-05-13-xp-visualizer-design.md)
**Parent commit:** `ddb54b4`

## 1. Purpose

Add two features to the v0.1 visualizer:

1. **Audio source selector** — the user picks which app's audio to visualize (or "all system audio") from a UI picker. The data layer already supports this (`SelectAudioSourceUseCase` + `vm.selectedSource`); only the UI is missing.
2. **Runtime language switching** — the app ships in English and Spanish, defaults to the macOS system language, and exposes a Settings sheet where the user can override to a fixed language. Switching takes effect immediately; no restart required.

## 2. Non-goals

- No translation of error messages from third-party frameworks (Core Audio OSStatus codes stay in English).
- No translation infrastructure for shader names or log statements (these aren't user-facing).
- No more than two locales for v0.2 (en, es). The architecture supports more, but they're not delivered here.
- No general "Settings" expansion — only the language switch in Settings for now. Other prefs (FFT size, particle count) are explicit future work.

## 3. Source picker

### 3.1 UI

A new view `SourcePicker.swift`. SwiftUI `Picker` with `.menu` style, label "Source" (localized). Items:

```
All system audio          ← AudioSource.systemWide
─────────────────
Spotify                   ← AudioSource.process(pid: 100, ...)
Music                     ← AudioSource.process(pid: 200, ...)
Safari                    ← AudioSource.process(pid: 300, ...)
…
```

Selection is two-way bound to `vm.selectedSource`. Change handler calls `vm.selectSource(_:)` which persists and restarts the capture stream (existing logic).

### 3.2 Process list refresh

Audio processes appear and disappear over time (you open Spotify, you close YouTube). The picker shouldn't be stale.

- On view appear: `vm.refreshSources()` (new method) calls `ListAudioSourcesUseCase` once.
- A background task in the VM polls every 3 seconds while the picker is visible. The poll is cancelled when the view disappears.

The poll is unconditional — even if the user has selected a specific app, we still refresh so they can switch to another one without restarting the app.

### 3.3 Display name

`AudioProcessInfo.displayName` is already populated by `RunningApplicationsDiscovery` from `NSWorkspace.runningApplications.localizedName`. Use as-is. Sort by display name, case-insensitive.

### 3.4 Layout

`RootView`'s toolbar HStack becomes:

```
[ ⚙️ ]   [ Source ▼ ]      [ Bars | Scope | Alchemy ]
```

`⚙️` is a button that opens the Settings sheet. Source picker is in the middle. Scene segmented control is on the right.

## 4. i18n

### 4.1 Languages

Initial set:
- **System** (follows macOS preferred languages)
- **English** (canonical strings)
- **Español** (translations provided)

Adding a language later means: add its translations to the String Catalog and add a case to `Language`.

### 4.2 Domain

```swift
// Domain/Localization/ValueObjects/Language.swift
public enum Language: String, CaseIterable, Sendable, Equatable {
    case system     // follow Locale.preferredLanguages
    case en         // force English
    case es         // force Spanish

    public var displayName: String {
        switch self {
        case .system: return "System default"
        case .en:     return "English"
        case .es:     return "Español"
        }
    }
}

// Domain/Localization/ValueObjects/L10nKey.swift
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

    // Errors
    case errorAppNotRunning       = "error.appNotRunning"
    case errorAudioFormat         = "error.audioFormat"
    case errorPermissionDenied    = "error.permissionDenied"
}

// Domain/Localization/Ports/Localizing.swift
public protocol Localizing: AnyObject, Sendable {
    func string(_ key: L10nKey) -> String
    func setLanguage(_ lang: Language)
    var current: Language { get }
    var resolvedLocale: String { get }   // e.g. "es" or "en"
}
```

### 4.3 Application

```swift
// Application/UseCases/ChangeLanguageUseCase.swift
public struct ChangeLanguageUseCase: Sendable {
    private let localizer: Localizing
    private let preferences: PreferencesStoring
    public init(localizer: Localizing, preferences: PreferencesStoring) { … }
    public func execute(_ lang: Language) {
        localizer.setLanguage(lang)
        var p = preferences.load()
        p.lastLanguage = lang
        preferences.save(p)
    }
}
```

### 4.4 Preferences extension

`UserPreferences` adds:

```swift
public var lastLanguage: Language
public static let `default` = UserPreferences(
    lastSource: .systemWide,
    lastScene: .bars,
    lastPaletteName: "XP Neon",
    lastLanguage: .system)
```

`UserDefaultsPreferences.DTO` adds a `language: String?` field, decoded with `Language(rawValue: ...) ?? .system`.

### 4.5 Infrastructure

```swift
// Infrastructure/Localization/BundleLocalizer.swift
@Observable
final class BundleLocalizer: Localizing {
    private(set) var current: Language = .system
    var resolvedLocale: String { /* "en" or "es" based on current + system */ }
    private var bundle: Bundle = .main

    init(initialLanguage: Language) { setLanguage(initialLanguage) }

    func setLanguage(_ lang: Language) {
        current = lang
        bundle = Self.bundle(for: lang) ?? .main
    }

    func string(_ key: L10nKey) -> String {
        NSLocalizedString(key.rawValue, bundle: bundle, comment: "")
    }

    private static func bundle(for lang: Language) -> Bundle? {
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

### 4.6 String Catalog

A single `Localizable.xcstrings` file at `AudioVisualizer/Resources/Localizable.xcstrings`. Xcode generates per-locale `.lproj` directories at build time from the catalog. Keys are the `L10nKey.rawValue` strings.

Initial content (excerpted):

| Key | en | es |
|---|---|---|
| `toolbar.source.label` | Source | Fuente |
| `toolbar.source.systemWide` | All system audio | Todo el audio del sistema |
| `toolbar.scene.bars` | Bars | Barras |
| `toolbar.scene.scope` | Scope | Osciloscopio |
| `toolbar.scene.alchemy` | Alchemy | Alquimia |
| `toolbar.settings.button` | Settings | Ajustes |
| `permission.title` | Audio Visualizer needs permission to listen to system audio. | El Visualizador de Audio necesita permiso para escuchar el audio del sistema. |
| `permission.grant` | Grant Audio Capture access | Conceder acceso de captura de audio |
| `permission.openSettings` | Open System Settings → Privacy → Audio Capture | Abrir Ajustes del Sistema → Privacidad → Captura de audio |
| `overlay.waitingForAudio` | Waiting for audio… | Esperando audio… |
| `settings.title` | Settings | Ajustes |
| `settings.language.label` | Language | Idioma |
| `settings.close` | Done | Listo |

### 4.7 Presentation

Views observe `BundleLocalizer` (`@Observable`). Any view that displays text accepts a `localizer: Localizing` (passed from the Composition Root or via a `@Environment` value, see 4.8).

`SettingsView.swift`:
```swift
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
                    ForEach(Language.allCases, id: \.self) { lang in
                        Text(lang.displayName).tag(lang)
                    }
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

`RootView` gets a `@State var showingSettings = false` and a sheet binding. The gear button toggles it. The sheet hands `onChange` to the `ChangeLanguageUseCase`.

### 4.8 Reactivity model

`BundleLocalizer` is `@Observable`. When `setLanguage` writes `current`, any SwiftUI view that read `current` or any property derived from it is invalidated and re-renders. To get this in views that only call `localizer.string(.key)`, force `string(_:)` to read `current` (which it already does indirectly via `bundle`). To be safe, add a `private var _version: Int = 0` that increments on `setLanguage`, and have `string(_:)` read `_ = _version` at the top — this guarantees SwiftUI observes the dependency.

### 4.9 Composition Root

```swift
let prefs = UserDefaultsPreferences()
let saved = prefs.load()
let localizer = BundleLocalizer(initialLanguage: saved.lastLanguage)
let changeLanguage = ChangeLanguageUseCase(localizer: localizer, preferences: prefs)
// pass localizer + changeLanguage into VM and views
```

## 5. Error handling

- Missing key in catalog → `NSLocalizedString` returns the key string as fallback. `BundleLocalizer.string(_:)` does NOT crash — the developer sees the raw key in the UI as a flag to add the translation.
- Unknown language code in preferences → falls back to `.system`.
- Bundle not found for chosen locale → falls back to `.main` (English).

## 6. Testing

- **Domain**: `LanguageTests` round-trip raw values; `L10nKeyTests` confirm every case has a stable rawValue.
- **Application**: `ChangeLanguageUseCaseTests` with `FakeLocalizing` and `FakePreferencesStoring` assert the localizer is updated and prefs are persisted.
- **Infrastructure**: `BundleLocalizerTests` — sets `.es`, asserts `string(.toolbar.scene.bars)` returns "Barras"; falls back to English on missing keys.
- **Infrastructure**: `UserDefaultsPreferences` round-trip test extended to include `lastLanguage`.

## 7. Folder additions

```
Domain/
  Localization/
    ValueObjects/
      Language.swift
      L10nKey.swift
    Ports/
      Localizing.swift
Application/
  UseCases/
    ChangeLanguageUseCase.swift
Infrastructure/Localization/
  BundleLocalizer.swift
Presentation/Scenes/
  SourcePicker.swift            # Feature 1
  SettingsView.swift            # Feature 2
Resources/
  Localizable.xcstrings         # Feature 2 (single file, both locales)
```

## 8. Risks

1. **String Catalog requires Xcode 15+ to author**, but at build time it's compiled into per-locale `.strings` so runtime works on macOS 14.2 fine.
2. **`Bundle(path:)` returns nil if `.lproj` directory isn't generated** — happens when the catalog hasn't been processed. Mitigation: include `Localizable.xcstrings` in `project.yml`'s sources block, so xcodegen + xcodebuild compile it on every build.
3. **Live language switch may not update strings rendered inside `Picker`'s pop-up menu** while the menu is open. Acceptable — the user closes the menu, reopens, sees the new language.
4. **Process discovery polling every 3 s** adds a tiny CPU cost (~negligible — `kAudioHardwarePropertyProcessObjectList` is cheap). If users report battery drain, consider event-driven via Core Audio property listeners on `kAudioHardwarePropertyProcessObjectList` (not done in v0.2).

## 9. Success criteria

- Picker appears in toolbar, shows current source, lets user switch to another running app; visualization restarts against the new source.
- Settings sheet opens via gear icon, language picker switches between System/English/Spanish; toolbar and overlay text changes immediately.
- macOS preferred language change (System default mode) takes effect on next app launch.
- All existing tests still pass; new tests cover Domain, Application, and Infrastructure of both features.
- Architecture invariant holds: no `Localizable` or `Bundle` imports in `Sources/Domain` or `Sources/Application`.
