import SwiftUI

/// Audio-reactive radial vignette overlay. Subtle by default; brighter when
/// beats land. Drawn on top of the Metal canvas with `.allowsHitTesting(false)`
/// so it never blocks input.
struct AmbientVignette: View {
    let renderer: MetalVisualizationRenderer

    @State private var rms: Float = 0
    @State private var beat: Float = 0

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { _ in
            ZStack {
                // Edge darkening — stronger when the scene is loud.
                RadialGradient(
                    colors: [Color.black.opacity(0), Color.black.opacity(0.45)],
                    center: .center,
                    startRadius: 60,
                    endRadius: 900
                )
                .opacity(0.55 + Double(min(0.35, rms * 2.5)))
                // Beat flash — warm tint glow that brightens briefly on hits.
                RadialGradient(
                    colors: [Color.white.opacity(Double(beat) * 0.18), Color.clear],
                    center: .center,
                    startRadius: 0,
                    endRadius: 700
                )
                .blendMode(.screen)
                .opacity(beat > 0.05 ? 1 : 0)
            }
            .onAppear { tick() }
            .onChange(of: rms) { _, _ in } // keep view reactive
            .task(id: UUID()) {
                // Drive `rms` and `beat` from the renderer every frame.
                while !Task.isCancelled {
                    tick()
                    try? await Task.sleep(for: .milliseconds(33))
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func tick() {
        rms = renderer.peekRMS()
        beat = renderer.peekBeat()
    }
}
