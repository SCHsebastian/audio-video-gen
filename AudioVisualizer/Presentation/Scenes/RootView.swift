import SwiftUI
import Domain

struct RootView: View {
    @Bindable var vm: VisualizerViewModel
    let renderer: MetalVisualizationRenderer
    @Bindable var localizer: BundleLocalizer
    let requestPermission: () async -> Void

    @State private var showingSettings = false

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
                    HStack(spacing: 16) {
                        Button {
                            showingSettings = true
                        } label: {
                            Image(systemName: "gearshape")
                                .font(.title3)
                        }
                        .buttonStyle(.plain)
                        .help(localizer.string(.settingsButton))
                        SceneToolbar(localizer: localizer,
                                     currentScene: Binding(
                                       get: { vm.currentScene },
                                       set: { vm.selectScene($0) }))
                        SpeedSlider(localizer: localizer,
                                    speed: Binding(
                                       get: { vm.speed },
                                       set: { vm.setSpeed($0) }))
                    }
                    .padding(.top, 16)
                    .padding(.horizontal, 16)
                    .frame(maxWidth: .infinity, alignment: .center)
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
        .sheet(isPresented: $showingSettings) {
            SettingsView(localizer: localizer,
                         onChange: { lang in vm.changeLanguage(lang) })
        }
    }
}
