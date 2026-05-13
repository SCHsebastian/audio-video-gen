import SwiftUI
import Domain

struct SpeedSlider: View {
    let localizer: Localizing
    @Binding var speed: Float

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "tortoise.fill")
                .foregroundStyle(.white.opacity(0.6))
                .font(.caption)
            Slider(value: Binding(
                get: { Double(speed) },
                set: { speed = Float($0) }
            ), in: 0.1...3.0)
            .frame(width: 140)
            .help(localizer.string(.speedLabel))
            Image(systemName: "hare.fill")
                .foregroundStyle(.white.opacity(0.6))
                .font(.caption)
            Text(String(format: "%.1fx", speed))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 36, alignment: .leading)
        }
    }
}
