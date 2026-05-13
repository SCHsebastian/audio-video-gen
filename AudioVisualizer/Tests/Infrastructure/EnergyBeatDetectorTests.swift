import XCTest
import Domain
import Darwin
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

    func test_first_beat_has_no_interval_then_second_beat_carries_interval_and_bpm() {
        // The detector converts HostTime (mach-absolute) to seconds via the
        // platform mach_timebase. To get a real 0.5 s gap on any host (Apple
        // silicon ≈ 41.66 ns/tick, Intel ≈ 1 ns/tick) we synthesise the
        // mach-tick offsets through the same timebase.
        let det = EnergyBeatDetector()
        let quiet = SpectrumFrame(bands: Array(repeating: 0.05, count: 64), rms: 0.05, timestamp: .zero)
        for _ in 0..<42 { _ = det.feed(quiet) }

        let loud = (0..<64).map { Float($0 < 8 ? 0.95 : 0.05) }
        let t0 = Self.hostTime(secondsAfterBoot: 1.0)
        let first = det.feed(SpectrumFrame(bands: loud, rms: 0.5, timestamp: t0))
        XCTAssertNotNil(first)
        XCTAssertEqual(first?.interval ?? -1, 0, "first detected beat carries no interval yet")
        XCTAssertEqual(first?.bpm ?? -1, 0, "first detected beat carries no BPM yet")

        // Feed another long quiet stretch so the running-average stays low.
        for _ in 0..<42 { _ = det.feed(quiet) }

        // 0.5 s later → expect ~120 BPM.
        let t1 = Self.hostTime(secondsAfterBoot: 1.5)
        let second = det.feed(SpectrumFrame(bands: loud, rms: 0.5, timestamp: t1))
        XCTAssertNotNil(second)
        if let s = second {
            XCTAssertEqual(s.interval, 0.5, accuracy: 0.05, "interval should be ~0.5 s")
            XCTAssertEqual(s.bpm, 120, accuracy: 6, "BPM should be ~120 ± a few")
        }
    }

    private static let timebase: mach_timebase_info_data_t = {
        var t = mach_timebase_info_data_t()
        mach_timebase_info(&t)
        return t
    }()

    /// Convert a seconds-since-boot value to a mach-absolute tick count on the
    /// current host, undoing what `EnergyBeatDetector.toNanos` does.
    private static func hostTime(secondsAfterBoot s: Double) -> HostTime {
        let nanos = s * 1_000_000_000
        let ticks = nanos * Double(timebase.denom) / Double(timebase.numer)
        return HostTime(machAbsolute: UInt64(ticks))
    }
}
