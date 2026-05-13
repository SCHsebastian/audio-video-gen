import SwiftUI
import AppKit
import Domain

struct RootView: View {
    @Bindable var vm: VisualizerViewModel
    let renderer: MetalVisualizationRenderer
    @Bindable var localizer: BundleLocalizer
    let requestPermission: () async -> Void

    @State private var showingSettings = false
    @State private var showingAbout = false
    @State private var toolbarVisible = true
    @State private var hideTask: Task<Void, Never>? = nil
    @FocusState private var keyboardFocused: Bool

    private let hideAfter: Duration = .milliseconds(2500)

    var body: some View {
        ZStack(alignment: .top) {
            MetalCanvas(renderer: renderer)
                .ignoresSafeArea()
                .onTapGesture {
                    vm.randomizeCurrent()
                    nudgeToolbar()
                }
                .onContinuousHover { phase in
                    if case .active = phase { nudgeToolbar() }
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
            NavigationStack { AboutView(localizer: localizer) }
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
            "1": .bars, "2": .scope, "3": .alchemy, "4": .tunnel, "5": .lissajous
        ]
        if let ch = press.characters.first, let s = sceneByKey[ch] {
            vm.selectScene(s); nudgeToolbar(); return .handled
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
            let order: [SceneKind] = [.bars, .scope, .alchemy, .tunnel, .lissajous]
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
