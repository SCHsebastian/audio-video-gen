import Domain

final class FakeBeatDetecting: BeatDetecting, @unchecked Sendable {
    var beatEverySpectrum: Bool = false
    private(set) var feedCount = 0
    func feed(_ spectrum: SpectrumFrame) -> BeatEvent? {
        feedCount += 1
        guard beatEverySpectrum else { return nil }
        return BeatEvent(timestamp: spectrum.timestamp, strength: 1.0,
                         interval: 0.5, bpm: 120)
    }
}
