public enum L10nKey: String, CaseIterable, Sendable {
    // Toolbar
    case sourceLabel              = "toolbar.source.label"
    case sourceSystemWide         = "toolbar.source.systemWide"
    case sceneBars                = "toolbar.scene.bars"
    case sceneScope               = "toolbar.scene.scope"
    case sceneAlchemy             = "toolbar.scene.alchemy"
    case sceneTunnel              = "toolbar.scene.tunnel"
    case sceneLissajous           = "toolbar.scene.lissajous"
    case speedLabel               = "toolbar.speed.label"
    case paletteCycle             = "toolbar.palette.cycle"
    case settingsButton           = "toolbar.settings.button"
    case helpButton               = "toolbar.help.button"

    // Permission gate
    case permissionTitle          = "permission.title"
    case permissionGrant          = "permission.grant"
    case permissionOpenSettings   = "permission.openSettings"

    // Overlay
    case waitingForAudio          = "overlay.waitingForAudio"
    case errorPrefix              = "overlay.errorPrefix"
    case randomizedSuffix         = "overlay.randomized"

    // Settings — chrome
    case settingsTitle            = "settings.title"
    case settingsClose            = "settings.close"
    case settingsTabGeneral       = "settings.tab.general"
    case settingsTabVisuals       = "settings.tab.visuals"
    case settingsTabAudio         = "settings.tab.audio"
    case settingsTabHelp          = "settings.tab.help"

    // Settings — General
    case settingsLanguageLabel    = "settings.language.label"
    case settingsReduceMotion     = "settings.reduceMotion"
    case settingsReduceMotionHint = "settings.reduceMotion.hint"
    case settingsShowDiagnostics  = "settings.showDiagnostics"
    case settingsShowDiagnosticsHint = "settings.showDiagnostics.hint"

    // Settings — Visuals
    case settingsPaletteSection   = "settings.palette.section"
    case settingsDefaultSceneLabel = "settings.defaultScene.label"
    case settingsSpeedLabel       = "settings.speed.label"

    // Settings — Audio
    case settingsAudioGainLabel   = "settings.audioGain.label"
    case settingsAudioGainHint    = "settings.audioGain.hint"
    case settingsBeatSensLabel    = "settings.beatSensitivity.label"
    case settingsBeatSensHint     = "settings.beatSensitivity.hint"
    case settingsResetButton      = "settings.reset"

    // About / Help
    case aboutTitle               = "about.title"
    case aboutTagline             = "about.tagline"
    case aboutAuthorHeader        = "about.author.header"
    case aboutAuthorBody          = "about.author.body"
    case aboutAssistantHeader     = "about.assistant.header"
    case aboutAssistantBody       = "about.assistant.body"
    case aboutShortcutsHeader     = "about.shortcuts.header"
    case aboutSceneShortcuts      = "about.shortcut.scenes"
    case aboutCycleShortcut       = "about.shortcut.cycle"
    case aboutSpaceShortcut       = "about.shortcut.space"
    case aboutPaletteShortcut     = "about.shortcut.palette"
    case aboutPaletteRandom       = "about.shortcut.paletteRandom"
    case aboutSnapshotShortcut    = "about.shortcut.snapshot"
    case aboutFullscreenShortcut  = "about.shortcut.fullscreen"
    case aboutDiagnosticsShortcut = "about.shortcut.diagnostics"
    case aboutHelpShortcut        = "about.shortcut.help"
    case aboutVersion             = "about.version"

    // Diagnostics HUD
    case hudFPS                   = "hud.fps"
    case hudRMS                   = "hud.rms"
    case hudBeat                  = "hud.beat"
    case hudScene                 = "hud.scene"
    case hudPalette               = "hud.palette"

    // Snapshot
    case snapshotSaved            = "snapshot.saved"
    case snapshotFailed           = "snapshot.failed"

    // Languages displayed in settings picker
    case languageSystem           = "language.system"
    case languageEnglish          = "language.english"
    case languageSpanish          = "language.spanish"
}
