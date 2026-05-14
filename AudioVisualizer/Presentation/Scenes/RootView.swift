import SwiftUI
import AppKit
import Domain

struct RootView: View {
    @Bindable var vm: VisualizerViewModel
    @Bindable var exportViewModel: ExportViewModel
    let renderer: MetalVisualizationRenderer
    @Bindable var localizer: BundleLocalizer
    let requestPermission: () async -> Void
    /// Provided by the App layer — used to spawn an independent secondary
    /// renderer (registered with the audio bus) when split view is on.
    let makeSecondary: (SceneKind) -> MetalVisualizationRenderer
    let releaseSecondary: (MetalVisualizationRenderer) -> Void

    @State private var showingSettings = false
    @State private var showingAbout = false
    /// Bumped whenever the user wants the About sheet to scroll to its
    /// keyboard-shortcuts anchor on next display (Help → Keyboard Shortcuts).
    @State private var aboutScrollToShortcuts = false
    @State private var toolbarVisible = true
    @State private var hideTask: Task<Void, Never>? = nil
    @FocusState private var keyboardFocused: Bool

    // Split-view state — when `secondaryRenderer` is non-nil the canvas
    // splits horizontally and the second pane uses this renderer + scene.
    @State private var secondaryRenderer: MetalVisualizationRenderer? = nil
    @State private var secondaryScene: SceneKind = .scope

    private let hideAfter: Duration = .milliseconds(2500)

    var body: some View {
        ZStack(alignment: .top) {
            if let secondaryRenderer {
                // Split view: primary on the left, secondary on the right,
                // separated by a thin divider. Both panes share the audio bus.
                HStack(spacing: 0) {
                    MetalCanvas(renderer: renderer, preferredFPS: vm.maxFPS)
                        .onTapGesture {
                            vm.randomizeCurrent()
                            nudgeToolbar()
                        }
                    Divider().background(.black.opacity(0.4))
                    MetalCanvas(renderer: secondaryRenderer, preferredFPS: vm.maxFPS)
                }
                .ignoresSafeArea()
                .onContinuousHover { phase in
                    if case .active = phase { nudgeToolbar() }
                }
            } else {
                MetalCanvas(renderer: renderer, preferredFPS: vm.maxFPS)
                    .ignoresSafeArea()
                    .onTapGesture {
                        vm.randomizeCurrent()
                        nudgeToolbar()
                    }
                    .onContinuousHover { phase in
                        if case .active = phase { nudgeToolbar() }
                    }
            }
            if !vm.reduceMotion {
                AmbientVignette(renderer: renderer)
                    .ignoresSafeArea()
            }
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
                runningOverlay
            case .error(let e):
                Text(localizer.string(.errorPrefix) + String(describing: e))
                    .foregroundStyle(.white)
            }
        }
        .onAppear { vm.onAppear(); nudgeToolbar(); keyboardFocused = true; updateWindowTitle() }
        .onChange(of: vm.currentScene) { _, _ in updateWindowTitle() }
        .onChange(of: vm.paletteName) { _, _ in updateWindowTitle() }
        .sheet(isPresented: $showingSettings) {
            SettingsView(localizer: localizer, vm: vm,
                         onChange: { lang in vm.changeLanguage(lang) })
        }
        .sheet(isPresented: $showingAbout) {
            NavigationStack {
                AboutView(localizer: localizer,
                          scrollToShortcuts: aboutScrollToShortcuts)
            }
        }
        .sheet(isPresented: $exportViewModel.isSheetPresented) {
            ExportSheetView(vm: exportViewModel, localizer: localizer)
        }
        .onReceive(NotificationCenter.default.publisher(for: AppMenuNotification.showAbout)) { _ in
            aboutScrollToShortcuts = false
            showingAbout = true
        }
        .onReceive(NotificationCenter.default.publisher(for: AppMenuNotification.showShortcuts)) { _ in
            aboutScrollToShortcuts = true
            showingAbout = true
        }
        .focusable()
        .focusEffectDisabled()
        .focused($keyboardFocused)
        .onKeyPress { press in handleKey(press) }
    }

    @ViewBuilder
    private var runningOverlay: some View {
        ZStack {
            // Top: toolbar capsule
            VStack {
                toolbar
                    .opacity(toolbarVisible ? 1 : 0)
                    .animation(.easeInOut(duration: 0.45), value: toolbarVisible)
                Spacer()
            }
            // Right-pane scene picker (only visible during split view).
            if let secondary = secondaryRenderer {
                VStack {
                    Spacer().frame(height: 14)
                    HStack {
                        Spacer()
                        HStack(spacing: 6) {
                            Image(systemName: "rectangle.split.2x1.fill")
                                .foregroundStyle(.white.opacity(0.7))
                            Picker("", selection: Binding(
                                get: { secondaryScene },
                                set: { secondaryScene = $0; secondary.setScene($0); nudgeToolbar() })
                            ) {
                                ForEach(vm.sceneOrder, id: \.self) { k in
                                    Text(sceneDisplayName(k)).tag(k)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.trailing, 18)
                        .opacity(toolbarVisible ? 1 : 0)
                        .animation(.easeInOut(duration: 0.35), value: toolbarVisible)
                    }
                    Spacer()
                }
            }
            // Top-right: diagnostics HUD
            if vm.showDiagnostics {
                VStack {
                    HStack {
                        Spacer()
                        DiagnosticsHUD(localizer: localizer,
                                       renderer: renderer,
                                       sceneName: sceneDisplayName(vm.currentScene),
                                       paletteName: vm.paletteName)
                            .padding(.top, 16)
                            .padding(.trailing, 16)
                    }
                    Spacer()
                }
                .transition(.opacity)
            }
            // Top-center: randomize toast
            if let label = vm.lastRandomizedLabel {
                VStack {
                    Spacer().frame(height: 80)
                    HStack(spacing: 8) {
                        Image(systemName: "shuffle")
                        Text("\(label) \(localizer.string(.randomizedSuffix))")
                    }
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 16)
                    .background(.ultraThinMaterial, in: Capsule())
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    Spacer()
                }
                .animation(.easeInOut(duration: 0.25), value: vm.lastRandomizedLabel)
            }
            // Bottom: silence + snapshot toasts
            VStack {
                Spacer()
                if let snap = vm.snapshotToast {
                    HStack(spacing: 8) {
                        Image(systemName: snap == "saved" ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        Text(localizer.string(snap == "saved" ? .snapshotSaved : .snapshotFailed))
                    }
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.vertical, 8).padding(.horizontal, 16)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 12)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
                if vm.isSilent {
                    Text(localizer.string(.waitingForAudio))
                        .foregroundStyle(.white.opacity(0.7))
                        .padding()
                        .background(Color.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
                        .padding(.bottom, 80)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: vm.snapshotToast)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 16) {
            Button {
                showingSettings = true
                nudgeToolbar()
            } label: {
                Image(systemName: "gearshape").font(.title3)
            }
            .buttonStyle(.plain)
            .help(localizer.string(.settingsButton))

            SceneToolbar(localizer: localizer,
                         order: vm.sceneOrder,
                         currentScene: Binding(
                           get: { vm.currentScene },
                           set: { vm.selectScene($0); nudgeToolbar() }))
            SpeedSlider(localizer: localizer,
                        speed: Binding(
                           get: { vm.speed },
                           set: { vm.setSpeed($0); nudgeToolbar() }))
            Button {
                vm.cyclePalette(); nudgeToolbar()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "paintpalette.fill")
                    Text(vm.paletteName).font(.caption.weight(.medium))
                }
                .foregroundStyle(.white.opacity(0.85))
            }
            .buttonStyle(.plain)
            .help(localizer.string(.paletteCycle))

            Button {
                exportViewModel.scene = vm.currentScene
                exportViewModel.paletteName = vm.paletteName
                exportViewModel.presentSheet()
                nudgeToolbar()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "square.and.arrow.up")
                    Text(localizer.string(.exportButtonLabel))
                        .font(.caption.weight(.medium))
                }
                .foregroundStyle(.white.opacity(0.85))
            }
            .buttonStyle(.plain)
            .help(localizer.string(.exportButtonLabel))

            ExportProgressChip(vm: exportViewModel, localizer: localizer)

            Button {
                toggleSplitView()
                nudgeToolbar()
            } label: {
                Image(systemName: secondaryRenderer == nil ? "rectangle.split.2x1" : "rectangle")
                    .font(.title3)
                    .foregroundStyle(secondaryRenderer == nil ? .white : .accentColor)
            }
            .buttonStyle(.plain)
            .help(localizer.string(.splitViewToggle))

            Button {
                showingAbout = true
                nudgeToolbar()
            } label: {
                Image(systemName: "questionmark.circle").font(.title3)
            }
            .buttonStyle(.plain)
            .help(localizer.string(.helpButton))
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 18)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.top, 14)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        let sceneByKey: [Character: SceneKind] = [
            "1": .bars, "2": .scope, "3": .alchemy, "4": .tunnel,
            "5": .lissajous, "6": .radial, "7": .rings,
            "8": .synthwave, "9": .spectrogram, "0": .milkdrop, "-": .kaleidoscope
        ]
        if let ch = press.characters.first, let s = sceneByKey[ch] {
            vm.selectScene(s); nudgeToolbar(); return .handled
        }
        if press.characters == "v" || press.characters == "V" {
            toggleSplitView(); nudgeToolbar(); return .handled
        }
        if press.characters == "P" {
            vm.randomPalette(); nudgeToolbar(); return .handled
        }
        if press.characters == "p" {
            vm.cyclePalette(); nudgeToolbar(); return .handled
        }
        if press.modifiers.contains(.command),
           press.characters.lowercased() == "d" {
            vm.toggleDiagnostics(); nudgeToolbar(); return .handled
        }
        if press.modifiers.contains(.command),
           press.characters.lowercased() == "s" {
            vm.saveSnapshot(); nudgeToolbar(); return .handled
        }
        if press.characters.lowercased() == "f" {
            toggleFullscreen(); return .handled
        }
        if press.characters == "?" {
            showingAbout.toggle(); nudgeToolbar(); return .handled
        }
        switch press.key {
        case .space:
            vm.randomizeCurrent(); nudgeToolbar(); return .handled
        case .leftArrow, .rightArrow:
            // Use the user's saved order; falls back to allCases if empty.
            let order = vm.sceneOrder.isEmpty ? SceneKind.allCases : vm.sceneOrder
            if let idx = order.firstIndex(of: vm.currentScene) {
                let next = press.key == .rightArrow ? (idx + 1) % order.count
                                                    : (idx - 1 + order.count) % order.count
                vm.selectScene(order[next]); nudgeToolbar()
            }
            return .handled
        default:
            return .ignored
        }
    }

    private func toggleSplitView() {
        if let r = secondaryRenderer {
            releaseSecondary(r)
            secondaryRenderer = nil
        } else {
            // Default the second pane to a complementary scene so the user
            // sees an immediate visual contrast.
            let other: SceneKind = (vm.currentScene == .scope) ? .radial : .scope
            secondaryScene = other
            secondaryRenderer = makeSecondary(other)
        }
    }

    private func toggleFullscreen() {
        guard let window = NSApp.keyWindow ?? NSApp.windows.first else { return }
        window.toggleFullScreen(nil)
    }

    private func sceneDisplayName(_ k: SceneKind) -> String {
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

    private func updateWindowTitle() {
        let scene = sceneDisplayName(vm.currentScene)
        let title = "Audio Visualizer — \(scene) · \(vm.paletteName)"
        for w in NSApp.windows { w.title = title }
    }

    private func nudgeToolbar() {
        toolbarVisible = true
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: hideAfter)
            if !Task.isCancelled { toolbarVisible = false }
        }
    }
}
