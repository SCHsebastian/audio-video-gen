import SwiftUI
import Domain

struct SceneToolbar: View {
    let localizer: Localizing
    @Binding var currentScene: SceneKind
    var body: some View {
        Picker("", selection: $currentScene) {
            Text(localizer.string(.sceneBars)).tag(SceneKind.bars)
            Text(localizer.string(.sceneScope)).tag(SceneKind.scope)
            Text(localizer.string(.sceneAlchemy)).tag(SceneKind.alchemy)
            Text(localizer.string(.sceneTunnel)).tag(SceneKind.tunnel)
            Text(localizer.string(.sceneLissajous)).tag(SceneKind.lissajous)
        }
        .pickerStyle(.segmented)
        .frame(width: 420)
    }
}
