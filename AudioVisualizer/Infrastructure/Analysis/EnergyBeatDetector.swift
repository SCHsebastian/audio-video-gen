import Domain

final class EnergyBeatDetector: BeatDetecting, @unchecked Sendable {
    private var history: [Float] = []      // last 43 bass-band energies (~1 sec at ~21 ms)
    private let windowSize = 43
    private let sensitivity: Float = 1.5    // peak must be 1.5x average to fire

    func feed(_ spectrum: SpectrumFrame) -> BeatEvent? {
        let bassEnergy = spectrum.bands.prefix(8).reduce(0, +) / 8
        history.append(bassEnergy)
        if history.count > windowSize { history.removeFirst() }
        guard history.count == windowSize else { return nil }
        let avg = history.reduce(0, +) / Float(history.count)
        guard avg > 0.01 else { return nil }
        let ratio = bassEnergy / avg
        guard ratio > sensitivity else { return nil }
        return BeatEvent(timestamp: spectrum.timestamp, strength: min(1, ratio - 1))
    }
}
