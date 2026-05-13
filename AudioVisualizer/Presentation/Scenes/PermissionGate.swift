import SwiftUI

struct PermissionGate: View {
    let onGrant: () -> Void
    var body: some View {
        VStack(spacing: 24) {
            Text("Audio Visualizer needs permission to listen to system audio.")
                .multilineTextAlignment(.center)
                .font(.title2)
            Button("Grant Audio Capture access", action: onGrant)
                .keyboardShortcut(.defaultAction)
            Link("Open System Settings → Privacy → Audio Capture",
                 destination: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!)
                .font(.footnote)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
        .foregroundStyle(.white)
    }
}
