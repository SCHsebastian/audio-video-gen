import SwiftUI
import AppKit

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
        .commands {
            // File → Save Snapshot
            CommandGroup(after: .saveItem) {
                Button("Save Snapshot to Desktop") {
                    root?.viewModel.saveSnapshot()
                }
                .keyboardShortcut("s", modifiers: [.command])
                .disabled(root == nil)
            }
            // View → Toggle Diagnostics / Fullscreen
            CommandGroup(after: .toolbar) {
                Button("Toggle Diagnostics HUD") {
                    root?.viewModel.toggleDiagnostics()
                }
                .keyboardShortcut("d", modifiers: [.command])
                .disabled(root == nil)

                Button("Toggle Fullscreen") {
                    (NSApp.keyWindow ?? NSApp.windows.first)?.toggleFullScreen(nil)
                }
                .keyboardShortcut("f", modifiers: [.control, .command])
            }
        }
    }
}
