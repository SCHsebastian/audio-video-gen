import SwiftUI
import Domain

struct SceneToolbar: View {
    @Binding var currentScene: SceneKind
    var body: some View {
        Picker("", selection: $currentScene) {
            Text("Bars").tag(SceneKind.bars)
            Text("Scope").tag(SceneKind.scope)
            Text("Alchemy").tag(SceneKind.alchemy)
        }
        .pickerStyle(.segmented)
        .frame(width: 240)
    }
}
