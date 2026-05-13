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

    // Languages displayed in settings picker
    case languageSystem           = "language.system"
    case languageEnglish          = "language.english"
    case languageSpanish          = "language.spanish"
}
