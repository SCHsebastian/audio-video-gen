import XCTest
@testable import Domain

final class AudioDriveTests: XCTestCase {
    func test_silence_is_all_zero() {
        let s = AudioDrive.silence
        XCTAssertEqual(s.bass, 0); XCTAssertEqual(s.mid, 0)
        XCTAssertEqual(s.treble, 0); XCTAssertEqual(s.flux, 0)
        XCTAssertEqual(s.beatPulse, 0); XCTAssertFalse(s.beatTriggered)
        XCTAssertEqual(s.bpm, 0)
    }
    func test_is_value_type_equatable() {
        let a = AudioDrive(bass: 0.5, mid: 0.1, treble: 0.2, flux: 0.3,
                           beatPulse: 0.7, beatTriggered: true, bpm: 120)
        let b = a
        XCTAssertEqual(a, b)
    }
}
