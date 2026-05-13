import SwiftUI
import Domain

/// Help & About sheet — credits the author and Claude, lists every keyboard
/// shortcut, and surfaces the bundle version. Reachable from the toolbar
/// help button, from the Help menu, and via the `?` key.
struct AboutView: View {
    @Bindable var localizer: BundleLocalizer
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                Divider()
                section(title: localizer.string(.aboutAuthorHeader),
                        icon: "person.crop.circle.fill",
                        body: localizer.string(.aboutAuthorBody))
                section(title: localizer.string(.aboutAssistantHeader),
                        icon: "sparkles",
                        body: localizer.string(.aboutAssistantBody))
                shortcuts
                Divider()
                versionRow
            }
            .padding(28)
        }
        .frame(width: 560, height: 620)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(localizer.string(.settingsClose)) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .navigationTitle(localizer.string(.aboutTitle))
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 6) {
                Text(localizer.string(.aboutTitle))
                    .font(.title.weight(.semibold))
                Text(localizer.string(.aboutTagline))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func section(title: String, icon: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.headline)
            Text(body)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var shortcuts: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(localizer.string(.aboutShortcutsHeader), systemImage: "keyboard")
                .font(.headline)
            VStack(alignment: .leading, spacing: 4) {
                shortcutRow(localizer.string(.aboutSceneShortcuts))
                shortcutRow(localizer.string(.aboutCycleShortcut))
                shortcutRow(localizer.string(.aboutSpaceShortcut))
                shortcutRow(localizer.string(.aboutPaletteShortcut))
                shortcutRow(localizer.string(.aboutPaletteRandom))
                shortcutRow(localizer.string(.aboutSnapshotShortcut))
                shortcutRow(localizer.string(.aboutFullscreenShortcut))
                shortcutRow(localizer.string(.aboutDiagnosticsShortcut))
                shortcutRow(localizer.string(.aboutHelpShortcut))
            }
            .padding(12)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func shortcutRow(_ text: String) -> some View {
        Text(text)
            .font(.system(.callout, design: .monospaced))
            .foregroundStyle(.primary.opacity(0.9))
    }

    private var versionRow: some View {
        HStack {
            Text(localizer.string(.aboutVersion))
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer()
            Text(Self.versionString)
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private static var versionString: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "0.0"
        let b = info?["CFBundleVersion"] as? String ?? "0"
        return "\(v) (\(b))"
    }
}
