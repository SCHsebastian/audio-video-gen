import SwiftUI
import Domain

struct SourcePicker: View {
    @Bindable var vm: VisualizerViewModel

    var body: some View {
        Picker(vm.localizer.string(.sourceLabel),
               selection: Binding(
                 get: { vm.selectedSource },
                 set: { vm.selectSource($0) })) {
            ForEach(vm.sources, id: \.self) { source in
                Text(vm.displayName(for: source)).tag(source)
            }
        }
        .pickerStyle(.menu)
        .frame(maxWidth: 220)
    }
}
