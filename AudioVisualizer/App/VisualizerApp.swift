import SwiftUI

@main
struct VisualizerApp: App {
    @State private var root: CompositionRoot?
    @State private var initError: String?

    var body: some Scene {
        WindowGroup("Audio Visualizer") {
            Group {
                if let root {
                    RootView(vm: root.viewModel,
                             renderer: root.renderer,
                             localizer: root.localizer) {
                        _ = await root.permission.request()
                    }
                } else if let err = initError {
                    Text("Failed to start: \(err)").padding()
                } else {
                    ProgressView().task {
                        do { root = try CompositionRoot() }
                        catch { initError = String(describing: error) }
                    }
                }
            }
            .frame(minWidth: 1280, minHeight: 720)
        }
    }
}
