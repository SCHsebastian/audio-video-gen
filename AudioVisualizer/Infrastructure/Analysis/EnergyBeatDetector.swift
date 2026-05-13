import Domain
import Darwin

final class EnergyBeatDetector: BeatDetecting, @unchecked Sendable {
    private var history: [Float] = []      // last 43 bass-band energies (~1 sec at ~21 ms)
    private let windowSize = 43
    private let sensitivity: Float = 1.5    // peak must be 1.5x average to fire

    // Tempo estimation: smoothed inter-beat interval, in seconds.
    private var lastBeatNanos: UInt64 = 0
    private var smoothedInterval: Double = 0
    private static let minInterval: Double = 0.25     // 240 BPM ceiling
    private static let maxInterval: Double = 1.50     //  40 BPM floor

    // Cached mach timebase so HostTime → seconds is a pointer-free conversion.
    private static let timebase: mach_timebase_info_data_t = {
        var t = mach_timebase_info_data_t()
        mach_timebase_info(&t)
        return t
    }()

    func feed(_ spectrum: SpectrumFrame) -> BeatEvent? {
        let bassEnergy = spectrum.bands.prefix(8).reduce(0, +) / 8
        history.append(bassEnergy)
        if history.count > windowSize { history.removeFirst() }
        guard history.count == windowSize else { return nil }
        let avg = history.reduce(0, +) / Float(history.count)
        guard avg > 0.01 else { return nil }
        let ratio = bassEnergy / avg
        guard ratio > sensitivity else { return nil }

        // Interval since the previous beat, in seconds.
        let nowNanos = Self.toNanos(spectrum.timestamp)
        var interval: Float = 0
        if lastBeatNanos != 0 && nowNanos > lastBeatNanos {
            let delta = Double(nowNanos - lastBeatNanos) / 1_000_000_000
            // Treat sub-quarter-second gaps as part of the same beat — fuzzes
            // out double-trigger jitter that the energy detector can produce
            // on percussive content.
            if delta >= Self.minInterval {
                let clamped = min(Self.maxInterval, delta)
                if smoothedInterval == 0 {
                    smoothedInterval = clamped
                } else {
                    // EMA with alpha = 0.3 — adapts in ~3 beats without being noisy.
                    smoothedInterval = 0.7 * smoothedInterval + 0.3 * clamped
                }
                interval = Float(clamped)
            }
        }
        lastBeatNanos = nowNanos

        let bpm: Float = smoothedInterval > 0 ? Float(60.0 / smoothedInterval) : 0

        return BeatEvent(timestamp: spectrum.timestamp,
                         strength: min(1, ratio - 1),
                         interval: interval,
                         bpm: bpm)
    }

    /// Convert a HostTime to nanoseconds-since-boot. Falls back to a 1:1 ratio
    /// if the timebase isn't populated (extremely unlikely on real hardware).
    private static func toNanos(_ t: HostTime) -> UInt64 {
        let tb = timebase
        if tb.numer == 0 || tb.denom == 0 { return t.machAbsolute }
        // Multiply first to avoid losing precision; mach_absolute_time is large.
        let num = UInt64(tb.numer), den = UInt64(tb.denom)
        // For typical Apple silicon (1:1) this is a no-op.
        if num == den { return t.machAbsolute }
        return (t.machAbsolute / den) * num + (t.machAbsolute % den) * num / den
    }
}
