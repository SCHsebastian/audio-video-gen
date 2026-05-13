import SwiftUI
import Domain

struct RootView: View {
    @Bindable var vm: VisualizerViewModel
    let renderer: MetalVisualizationRenderer
    @Bindable var localizer: BundleLocalizer
    let requestPermission: () async -> Void

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
                        SourcePicker(vm: vm)
                        SceneToolbar(localizer: localizer,
                                     currentScene: Binding(
                                       get: { vm.currentScene },
                                       set: { vm.selectScene($0) }))
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
    }
}
