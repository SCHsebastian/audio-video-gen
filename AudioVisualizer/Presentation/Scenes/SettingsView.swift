import SwiftUI
import Domain

struct SettingsView: View {
    @Bindable var localizer: BundleLocalizer
    let onChange: (Language) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Picker(localizer.string(.settingsLanguageLabel),
                       selection: Binding(
                         get: { localizer.current },
                         set: { onChange($0) })) {
                    Text(localizer.string(.languageSystem)).tag(Language.system)
                    Text(localizer.string(.languageEnglish)).tag(Language.en)
                    Text(localizer.string(.languageSpanish)).tag(Language.es)
                }
            }
            .navigationTitle(localizer.string(.settingsTitle))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(localizer.string(.settingsClose)) { dismiss() }
                }
            }
        }
        .frame(width: 360, height: 200)
    }
}
