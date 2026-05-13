import SwiftUI
import Domain

struct RootView: View {
    @Bindable var vm: VisualizerViewModel
    let renderer: MetalVisualizationRenderer
    @Bindable var localizer: BundleLocalizer
    let requestPermission: () async -> Void

    @State private var showingSettings = false
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
            AmbientVignette(renderer: renderer)
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
                    HStack(spacing: 16) {
                        Button {
                            showingSettings = true
                            nudgeToolbar()
                        } label: {
                            Image(systemName: "gearshape")
                                .font(.title3)
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
                    }
                    .padding(.vertical, 10)
                    .padding(.horizontal, 18)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 14)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .opacity(toolbarVisible ? 1 : 0)
                    .animation(.easeInOut(duration: 0.45), value: toolbarVisible)
                    if let label = vm.lastRandomizedLabel {
                        VStack {
                            Spacer().frame(height: 80)
                            HStack(spacing: 8) {
                                Image(systemName: "shuffle")
                                Text("\(label) randomized")
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
        .onAppear { vm.onAppear(); nudgeToolbar(); keyboardFocused = true }
        .sheet(isPresented: $showingSettings) {
            SettingsView(localizer: localizer,
                         onChange: { lang in vm.changeLanguage(lang) })
        }
        .focusable()
        .focusEffectDisabled()
        .focused($keyboardFocused)
        .onKeyPress { press in handleKey(press) }
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        // Number row maps to scenes in toolbar order.
        let sceneByKey: [Character: SceneKind] = [
            "1": .bars, "2": .scope, "3": .alchemy, "4": .tunnel, "5": .lissajous
        ]
        if let ch = press.characters.first, let s = sceneByKey[ch] {
            vm.selectScene(s); nudgeToolbar(); return .handled
        }
        if press.characters == "p" || press.characters == "P" {
            vm.cyclePalette(); nudgeToolbar(); return .handled
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

    /// Show the toolbar and reset the idle timer; after `hideAfter` of no further
    /// activity the toolbar fades out so the visualization is unobstructed.
    private func nudgeToolbar() {
        toolbarVisible = true
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: hideAfter)
            if !Task.isCancelled { toolbarVisible = false }
        }
    }
}
