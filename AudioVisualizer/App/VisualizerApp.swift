import SwiftUI
import AppKit

/// Names of NSNotifications used to bridge menu-bar commands to the SwiftUI
/// view hierarchy. Commands live on the App (no view context); the view
/// observes these on its `.onReceive` to flip the relevant @State.
enum AppMenuNotification {
    static let showAbout = Notification.Name("AudioVisualizer.showAbout")
    static let showShortcuts = Notification.Name("AudioVisualizer.showShortcuts")
    static let openRepo = Notification.Name("AudioVisualizer.openRepo")
}

@main
struct VisualizerApp: App {
    @State private var root: CompositionRoot?
    @State private var initError: String?

    var body: some Scene {
        WindowGroup("Audio Visualizer") {
            Group {
                if let root {
                    RootView(vm: root.viewModel,
                             exportViewModel: root.exportViewModel,
                             renderer: root.renderer,
                             localizer: root.localizer,
                             requestPermission: {
                                 _ = await root.permission.request()
                             },
                             makeSecondary: { scene in
                                 root.makeSecondaryRenderer(scene: scene)
                             },
                             releaseSecondary: { r in
                                 root.releaseSecondary(r)
                             })
                } else if let err = initError {
                    Text("Failed to start: \(err)").padding()
                } else {
                    ProgressView().task {
                        do { root = try CompositionRoot() }
                        catch { initError = String(describing: error) }
                    }
                }
            }
            .frame(minWidth: 200, minHeight: 120)
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
            // Help — replace the default (which points at apple.com/help)
            // with our in-app sheet plus shortcuts and the GitHub repo.
            CommandGroup(replacing: .help) {
                Button("Audio Visualizer Help") {
                    NotificationCenter.default.post(name: AppMenuNotification.showAbout, object: nil)
                }
                .keyboardShortcut("?", modifiers: [.command])

                Button("Keyboard Shortcuts") {
                    NotificationCenter.default.post(name: AppMenuNotification.showShortcuts, object: nil)
                }
                .keyboardShortcut("?", modifiers: [.command, .shift])

                Divider()

                Button("View on GitHub…") {
                    if let url = URL(string: "https://github.com/SCHsebastian/audio-video-gen") {
                        NSWorkspace.shared.open(url)
                    }
                }

                Button("Report an Issue…") {
                    if let url = URL(string: "https://github.com/SCHsebastian/audio-video-gen/issues/new") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }
}
