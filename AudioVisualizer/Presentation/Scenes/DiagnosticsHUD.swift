import SwiftUI
import Domain

/// Translucent diagnostics HUD pinned to the top-right of the canvas. Polls
/// renderer state every 100ms; non-interactive so it can never block input.
struct DiagnosticsHUD: View {
    let localizer: Localizing
    let renderer: MetalVisualizationRenderer
    let sceneName: String
    let paletteName: String

    @State private var fps: Double = 0
    @State private var rms: Float = 0
    @State private var beat: Float = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            row(localizer.string(.hudFPS), String(format: "%5.1f", fps))
            row(localizer.string(.hudRMS), String(format: "%5.3f", rms))
            row(localizer.string(.hudBeat), bar(beat))
            Divider().opacity(0.4)
            row(localizer.string(.hudScene), sceneName)
            row(localizer.string(.hudPalette), paletteName)
        }
        .font(.system(.caption, design: .monospaced))
        .foregroundStyle(.white.opacity(0.92))
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.black.opacity(0.42), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(.white.opacity(0.08), lineWidth: 1)
        )
        .task(id: "hud") {
            while !Task.isCancelled {
                fps = renderer.measuredFPS
                rms = renderer.peekRMS()
                beat = renderer.peekBeat()
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        .allowsHitTesting(false)
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack(spacing: 10) {
            Text(k).foregroundStyle(.white.opacity(0.6)).frame(width: 56, alignment: .leading)
            Text(v).foregroundStyle(.white)
        }
    }

    private func bar(_ v: Float) -> String {
        let n = 10
        let filled = max(0, min(n, Int((v * Float(n)).rounded())))
        return String(repeating: "█", count: filled) + String(repeating: "·", count: n - filled)
    }
}
