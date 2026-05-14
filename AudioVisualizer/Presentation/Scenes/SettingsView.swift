import SwiftUI
import Domain

/// Tabbed Settings sheet covering General, Visuals, Audio, and About. Replaces
/// the original one-row language picker.
struct SettingsView: View {
    @Bindable var localizer: BundleLocalizer
    @Bindable var vm: VisualizerViewModel
    let onChange: (Language) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label(localizer.string(.settingsTabGeneral), systemImage: "gearshape") }
            visualsTab
                .tabItem { Label(localizer.string(.settingsTabVisuals), systemImage: "paintpalette") }
            audioTab
                .tabItem { Label(localizer.string(.settingsTabAudio), systemImage: "waveform") }
            AboutView(localizer: localizer)
                .tabItem { Label(localizer.string(.settingsTabHelp), systemImage: "info.circle") }
        }
        .padding(20)
        .frame(width: 600, height: 640)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(localizer.string(.settingsClose)) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .navigationTitle(localizer.string(.settingsTitle))
    }

    // MARK: General
    private var generalTab: some View {
        Form {
            Section {
                Picker(localizer.string(.settingsLanguageLabel),
                       selection: Binding(
                         get: { localizer.current },
                         set: { onChange($0) })) {
                    Text(localizer.string(.languageSystem)).tag(Language.system)
                    Text(localizer.string(.languageEnglish)).tag(Language.en)
                    Text(localizer.string(.languageSpanish)).tag(Language.es)
                }
            }
            Section {
                Toggle(localizer.string(.settingsReduceMotion), isOn: Binding(
                    get: { vm.reduceMotion },
                    set: { vm.setReduceMotion($0) }))
                Text(localizer.string(.settingsReduceMotionHint))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                Toggle(localizer.string(.settingsShowDiagnostics), isOn: Binding(
                    get: { vm.showDiagnostics },
                    set: { vm.setShowDiagnostics($0) }))
                Text(localizer.string(.settingsShowDiagnosticsHint))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                Button(localizer.string(.settingsResetButton)) { vm.resetToDefaults() }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Visuals
    private var visualsTab: some View {
        Form {
            Section(localizer.string(.settingsPaletteSection)) {
                paletteGrid
            }
            Section {
                Picker(localizer.string(.settingsDefaultSceneLabel), selection: Binding(
                    get: { vm.currentScene },
                    set: { vm.selectScene($0) })) {
                    Text(localizer.string(.sceneBars)).tag(SceneKind.bars)
                    Text(localizer.string(.sceneScope)).tag(SceneKind.scope)
                    Text(localizer.string(.sceneAlchemy)).tag(SceneKind.alchemy)
                    Text(localizer.string(.sceneTunnel)).tag(SceneKind.tunnel)
                    Text(localizer.string(.sceneLissajous)).tag(SceneKind.lissajous)
                    Text(localizer.string(.sceneRadial)).tag(SceneKind.radial)
                    Text(localizer.string(.sceneRings)).tag(SceneKind.rings)
                    Text(localizer.string(.sceneSynthwave)).tag(SceneKind.synthwave)
                    Text(localizer.string(.sceneSpectrogram)).tag(SceneKind.spectrogram)
                    Text(localizer.string(.sceneMilkdrop)).tag(SceneKind.milkdrop)
                    Text(localizer.string(.sceneKaleidoscope)).tag(SceneKind.kaleidoscope)
                }
                .pickerStyle(.menu)
            }
            Section(localizer.string(.settingsSceneOrderSection)) {
                sceneOrderList
                Text(localizer.string(.settingsSceneOrderHint))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                Toggle(localizer.string(.settingsShuffleEnabled), isOn: Binding(
                    get: { vm.shuffleEnabled },
                    set: { vm.setShuffleEnabled($0) }))
                Text(localizer.string(.settingsShuffleHint))
                    .font(.footnote).foregroundStyle(.secondary)
                LabeledContent(localizer.string(.settingsShuffleInterval)) {
                    HStack {
                        Picker("", selection: Binding(
                            get: { vm.shuffleIntervalSec },
                            set: { vm.setShuffleIntervalSec($0) })) {
                            Text("1 \(localizer.string(.settingsShuffleMinutes))").tag(60)
                            Text("3 \(localizer.string(.settingsShuffleMinutes))").tag(180)
                            Text("5 \(localizer.string(.settingsShuffleMinutes))").tag(300)
                            Text("10 \(localizer.string(.settingsShuffleMinutes))").tag(600)
                            Text("30 \(localizer.string(.settingsShuffleMinutes))").tag(1800)
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .frame(width: 130)
                    }
                }
                .disabled(!vm.shuffleEnabled)
            }
            Section {
                Picker(localizer.string(.settingsFPSLabel), selection: Binding(
                    get: { vm.maxFPS },
                    set: { vm.setMaxFPS($0) })) {
                    Text("30 fps").tag(30)
                    Text("60 fps").tag(60)
                    Text("90 fps").tag(90)
                    Text("120 fps").tag(120)
                    Text(localizer.string(.settingsFPSUnlimited)).tag(0)
                }
                .pickerStyle(.menu)
                Text(localizer.string(.settingsFPSHint))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent(localizer.string(.settingsSpeedLabel)) {
                    HStack {
                        Slider(value: Binding(
                            get: { Double(vm.speed) },
                            set: { vm.setSpeed(Float($0)) }
                        ), in: 0.1...3.0)
                        Text(String(format: "%.1fx", vm.speed))
                            .font(.callout.monospacedDigit())
                            .frame(width: 44, alignment: .trailing)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var paletteGrid: some View {
        let cols = [GridItem(.adaptive(minimum: 150), spacing: 12)]
        return LazyVGrid(columns: cols, spacing: 12) {
            ForEach(PaletteFactory.all, id: \.name) { palette in
                Button {
                    vm.selectPalette(named: palette.name)
                } label: {
                    paletteSwatch(palette, selected: palette.name == vm.paletteName)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }

    private func paletteSwatch(_ p: ColorPalette, selected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            LinearGradient(colors: p.stops.map { Color(red: Double($0.r), green: Double($0.g), blue: Double($0.b)) },
                           startPoint: .leading, endPoint: .trailing)
                .frame(height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(selected ? Color.accentColor : Color.secondary.opacity(0.3),
                                lineWidth: selected ? 2.5 : 1)
                )
            HStack {
                Text(p.name).font(.callout.weight(.medium))
                Spacer()
                if selected {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                }
            }
        }
    }

    private var sceneOrderList: some View {
        // SwiftUI's `List(.onMove)` on macOS gives a native drag-to-reorder
        // affordance with the standard grab handle on the right.
        List {
            ForEach(vm.sceneOrder, id: \.self) { kind in
                HStack {
                    Image(systemName: icon(for: kind))
                        .frame(width: 22).foregroundStyle(.secondary)
                    Text(name(for: kind))
                    Spacer()
                    if kind == vm.currentScene {
                        Image(systemName: "play.circle.fill").foregroundStyle(.tint)
                    }
                }
            }
            .onMove { from, to in
                var order = vm.sceneOrder
                order.move(fromOffsets: from, toOffset: to)
                vm.setSceneOrder(order)
            }
        }
        .frame(minHeight: 260)
        .listStyle(.bordered(alternatesRowBackgrounds: true))
    }

    private func name(for k: SceneKind) -> String {
        switch k {
        case .bars: return localizer.string(.sceneBars)
        case .scope: return localizer.string(.sceneScope)
        case .alchemy: return localizer.string(.sceneAlchemy)
        case .tunnel: return localizer.string(.sceneTunnel)
        case .lissajous: return localizer.string(.sceneLissajous)
        case .radial: return localizer.string(.sceneRadial)
        case .rings: return localizer.string(.sceneRings)
        case .synthwave: return localizer.string(.sceneSynthwave)
        case .spectrogram: return localizer.string(.sceneSpectrogram)
        case .milkdrop: return localizer.string(.sceneMilkdrop)
        case .kaleidoscope: return localizer.string(.sceneKaleidoscope)
        case .aigame: return localizer.string(.sceneAIGame)
        }
    }

    private func icon(for k: SceneKind) -> String {
        switch k {
        case .bars: return "chart.bar.fill"
        case .scope: return "waveform"
        case .alchemy: return "sparkles"
        case .tunnel: return "circle.hexagongrid.fill"
        case .lissajous: return "infinity"
        case .radial: return "circle.dotted"
        case .rings: return "circle.circle.fill"
        case .synthwave: return "sun.horizon.fill"
        case .spectrogram: return "rectangle.split.3x3"
        case .milkdrop: return "cloud.fill"
        case .kaleidoscope: return "snowflake"
        case .aigame: return "gamecontroller.fill"
        }
    }

    // MARK: Audio
    private var audioTab: some View {
        Form {
            Section {
                LabeledContent(localizer.string(.settingsAudioGainLabel)) {
                    HStack {
                        Slider(value: Binding(
                            get: { Double(vm.audioGain) },
                            set: { vm.setAudioGain(Float($0)) }
                        ), in: 0.25...4.0)
                        Text(String(format: "%.2fx", vm.audioGain))
                            .font(.callout.monospacedDigit())
                            .frame(width: 56, alignment: .trailing)
                    }
                }
                Text(localizer.string(.settingsAudioGainHint))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent(localizer.string(.settingsBeatSensLabel)) {
                    HStack {
                        Slider(value: Binding(
                            get: { Double(vm.beatSensitivity) },
                            set: { vm.setBeatSensitivity(Float($0)) }
                        ), in: 0.25...3.0)
                        Text(String(format: "%.2fx", vm.beatSensitivity))
                            .font(.callout.monospacedDigit())
                            .frame(width: 56, alignment: .trailing)
                    }
                }
                Text(localizer.string(.settingsBeatSensHint))
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
