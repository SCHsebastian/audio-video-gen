import SwiftUI
import Domain

struct RootView: View {
    @Bindable var vm: VisualizerViewModel
    let renderer: MetalVisualizationRenderer
    let requestPermission: () async -> Void

    var body: some View {
        ZStack(alignment: .top) {
            MetalCanvas(renderer: renderer)
                .ignoresSafeArea()
            switch vm.state {
            case .waitingForPermission:
                PermissionGate { Task { await requestPermission(); vm.onAppear() } }
            case .error(.permissionDenied):
                PermissionGate { Task { await requestPermission(); vm.onAppear() } }
            case .running, .idle, .noAudioYet:
                ZStack {
                    SceneToolbar(currentScene: Binding(
                        get: { vm.currentScene },
                        set: { vm.selectScene($0) }))
                        .padding(.top, 16)
                    if vm.isSilent {
                        VStack {
                            Spacer()
                            Text("Waiting for audio\u{2026}")
                                .foregroundStyle(.white.opacity(0.7))
                                .padding()
                                .background(Color.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
                            Spacer().frame(height: 80)
                        }
                    }
                }
            case .error(let e):
                Text("Error: \(String(describing: e))").foregroundStyle(.white)
            }
        }
        .onAppear { vm.onAppear() }
    }
}
