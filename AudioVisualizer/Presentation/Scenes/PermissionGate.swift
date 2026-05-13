import SwiftUI
import Domain

struct PermissionGate: View {
    let localizer: Localizing
    let onGrant: () -> Void
    var body: some View {
        VStack(spacing: 24) {
            Text(localizer.string(.permissionTitle))
                .multilineTextAlignment(.center)
                .font(.title2)
            Button(localizer.string(.permissionGrant), action: onGrant)
                .keyboardShortcut(.defaultAction)
            Link(localizer.string(.permissionOpenSettings),
                 destination: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!)
                .font(.footnote)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
        .foregroundStyle(.white)
    }
}
