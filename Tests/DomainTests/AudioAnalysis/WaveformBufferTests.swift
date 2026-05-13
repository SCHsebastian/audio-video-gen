import XCTest
@testable import Domain

final class WaveformBufferTests: XCTestCase {
    func test_mono_only_mirrors_into_left_and_right() {
        let buf = WaveformBuffer(mono: [0, 0.5, -0.5, 1])
        XCTAssertEqual(buf.left, buf.mono)
        XCTAssertEqual(buf.right, buf.mono)
        XCTAssertFalse(buf.isStereo, "mirrored L/R must not be reported as stereo")
    }

    func test_distinct_left_and_right_are_stereo() {
        let buf = WaveformBuffer(mono: [0, 0, 0, 0],
                                 left:  [0.5, -0.5, 0.5, -0.5],
                                 right: [-0.5, 0.5, -0.5, 0.5])
        XCTAssertTrue(buf.isStereo)
    }

    func test_left_right_equal_to_mono_is_not_stereo() {
        let m: [Float] = [0.1, 0.2, 0.3]
        let buf = WaveformBuffer(mono: m, left: m, right: m)
        XCTAssertFalse(buf.isStereo)
    }
}
