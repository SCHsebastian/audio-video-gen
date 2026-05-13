import XCTest
import VisualizerKernels

final class VisualizerKernelsTests: XCTestCase {
    func test_build_id_is_nonempty() {
        guard let ptr = vk_build_id() else { return XCTFail("vk_build_id returned null") }
        let s = String(cString: ptr)
        XCTAssertTrue(s.hasPrefix("VisualizerKernels"))
    }

    func test_lissajous_fills_buffer_within_unit_square() {
        let n = 256
        var out = [Float](repeating: 0, count: n * 2)
        out.withUnsafeMutableBufferPointer { buf in
            vk_lissajous(buf.baseAddress, UInt32(n), 1.0, 3.0, 2.0, 0.3, 0.4)
        }
        XCTAssertTrue(out.allSatisfy { abs($0) <= 1.05 })
        XCTAssertFalse(out.allSatisfy { $0 == 0 })
    }

    func test_rose_with_more_bass_grows_radius() {
        let n = 128
        var quiet = [Float](repeating: 0, count: n * 2)
        var loud  = [Float](repeating: 0, count: n * 2)
        quiet.withUnsafeMutableBufferPointer { vk_rose($0.baseAddress, UInt32(n), 0, 5, 0.0) }
        loud .withUnsafeMutableBufferPointer { vk_rose($0.baseAddress, UInt32(n), 0, 5, 0.5) }
        func maxMag(_ a: [Float]) -> Float {
            stride(from: 0, to: a.count, by: 2).map { hypotf(a[$0], a[$0+1]) }.max() ?? 0
        }
        XCTAssertGreaterThan(maxMag(loud), maxMag(quiet))
    }
}
