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
                // Edge darkening — gentle baseline, gentle RMS pull. Both
                // values were toned down vs. the original (0.45/0.35/2.5) to
                // take the strobe edge off when audio is loud.
                RadialGradient(
                    colors: [Color.black.opacity(0), Color.black.opacity(0.35)],
                    center: .center,
                    startRadius: 60,
                    endRadius: 900
                )
                .opacity(0.50 + Double(min(0.18, rms * 1.4)))
                // Beat flash — soft warm sheen that brightens on hits. The
                // previous 0.18 peak alpha read as a hard strobe on bright
                // scenes; 0.09 keeps the rhythmic feel without making the
                // eyes work. The outer opacity now ramps with `beat` instead
                // of snapping fully on at 0.05.
                RadialGradient(
                    colors: [Color.white.opacity(Double(beat) * 0.09), Color.clear],
                    center: .center,
                    startRadius: 0,
                    endRadius: 700
                )
                .blendMode(.screen)
                .opacity(beat > 0.05 ? min(1, Double(beat) * 3.0) : 0)
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
