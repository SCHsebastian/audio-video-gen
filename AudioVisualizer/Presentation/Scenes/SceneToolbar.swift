import SwiftUI
import Domain

struct SceneToolbar: View {
    let localizer: Localizing
    /// Order in which scenes are presented in the toolbar. Comes from
    /// `UserPreferences.sceneOrder` so the user controls it from Settings.
    let order: [SceneKind]
    @Binding var currentScene: SceneKind

    var body: some View {
        // 11 scenes won't fit in a segmented control — use a Menu picker
        // that opens on click and is keyboard-navigable.
        Menu {
            ForEach(order, id: \.self) { kind in
                Button {
                    currentScene = kind
                } label: {
                    HStack {
                        Image(systemName: icon(for: kind))
                        Text(name(for: kind))
                        if kind == currentScene {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon(for: currentScene))
                Text(name(for: currentScene))
                    .font(.callout.weight(.medium))
                Image(systemName: "chevron.down").font(.caption2)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(.white.opacity(0.08), in: Capsule())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(minWidth: 180)
    }

    private func name(for k: SceneKind) -> String {
        switch k {
        case .bars: return localizer.string(.sceneBars)
        case .scope: return localizer.string(.sceneScope)
        case .alchemy: return localizer.string(.sceneAlchemy)
        case .tunnel: return localizer.string(.sceneTunnel)
        case .lissajous: return localizer.string(.sceneLissajous)
        case .radial: return localizer.string(.sceneRadial)
        case .rings: return localizer.string(.sceneRings)
        case .synthwave: return localizer.string(.sceneSynthwave)
        case .spectrogram: return localizer.string(.sceneSpectrogram)
        case .milkdrop: return localizer.string(.sceneMilkdrop)
        case .kaleidoscope: return localizer.string(.sceneKaleidoscope)
        }
    }

    /// SF Symbol per scene. Helps the user pick by glance.
    private func icon(for k: SceneKind) -> String {
        switch k {
        case .bars: return "chart.bar.fill"
        case .scope: return "waveform"
        case .alchemy: return "sparkles"
        case .tunnel: return "circle.hexagongrid.fill"
        case .lissajous: return "infinity"
        case .radial: return "circle.dotted"
        case .rings: return "circle.circle.fill"
        case .synthwave: return "sun.horizon.fill"
        case .spectrogram: return "rectangle.split.3x3"
        case .milkdrop: return "cloud.fill"
        case .kaleidoscope: return "snowflake"
        }
    }
}
