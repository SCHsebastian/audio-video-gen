import XCTest
@testable import Domain

final class BeatEventTests: XCTestCase {
    func test_holds_timestamp_and_strength() {
        let b = BeatEvent(timestamp: HostTime(machAbsolute: 42), strength: 0.75)
        XCTAssertEqual(b.timestamp.machAbsolute, 42)
        XCTAssertEqual(b.strength, 0.75)
    }

    func test_interval_and_bpm_default_to_zero() {
        let b = BeatEvent(timestamp: .zero, strength: 0.5)
        XCTAssertEqual(b.interval, 0)
        XCTAssertEqual(b.bpm, 0)
    }

    func test_holds_interval_and_bpm_when_provided() {
        let b = BeatEvent(timestamp: .zero, strength: 0.5, interval: 0.5, bpm: 120)
        XCTAssertEqual(b.interval, 0.5)
        XCTAssertEqual(b.bpm, 120)
    }
}
