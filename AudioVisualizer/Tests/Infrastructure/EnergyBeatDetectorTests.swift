import XCTest
import Domain
@testable import AudioVisualizer

final class EnergyBeatDetectorTests: XCTestCase {
    func test_emits_on_bass_energy_spike() {
        let det = EnergyBeatDetector()
        // Feed 42 quiet frames to fill the window, then a loud one — expect at least one beat.
        for _ in 0..<42 {
            _ = det.feed(SpectrumFrame(bands: Array(repeating: 0.05, count: 64),
                                       rms: 0.05, timestamp: .zero))
        }
        let loud = (0..<64).map { Float($0 < 8 ? 0.95 : 0.05) }
        let beat = det.feed(SpectrumFrame(bands: loud, rms: 0.5, timestamp: HostTime(machAbsolute: 1)))
        XCTAssertNotNil(beat)
        XCTAssertGreaterThan(beat!.strength, 0)
    }

    func test_steady_low_energy_no_beat() {
        let det = EnergyBeatDetector()
        for _ in 0..<50 {
            let b = det.feed(SpectrumFrame(bands: Array(repeating: 0.05, count: 64),
                                           rms: 0.05, timestamp: .zero))
            XCTAssertNil(b)
        }
    }
}
