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

    func test_bars_process_rises_fast_decays_slowly() {
        var state = [Float](repeating: 0, count: 8)
        var out = [Float](repeating: 0, count: 8)
        let hi: [Float] = Array(repeating: 1.0, count: 8)
        let zero: [Float] = Array(repeating: 0, count: 8)
        // Drive high once, observe rise.
        hi.withUnsafeBufferPointer { ip in
            out.withUnsafeMutableBufferPointer { op in
                state.withUnsafeMutableBufferPointer { sp in
                    vk_bars_process(ip.baseAddress, op.baseAddress, sp.baseAddress, 8, 0.016, 0)
                }
            }
        }
        let afterRise = out
        XCTAssertGreaterThan(afterRise[0], 0.05)
        // Then drop to zero and verify a slower decay.
        for _ in 0..<3 {
            zero.withUnsafeBufferPointer { ip in
                out.withUnsafeMutableBufferPointer { op in
                    state.withUnsafeMutableBufferPointer { sp in
                        vk_bars_process(ip.baseAddress, op.baseAddress, sp.baseAddress, 8, 0.016, 0)
                    }
                }
            }
        }
        // After 3 frames (48ms) with input=0, signal should still be above 30% of peak
        // because release_tau ≈ 260ms. This is what makes the bars feel like meters.
        XCTAssertGreaterThan(out[0], afterRise[0] * 0.3)
        XCTAssertLessThan(out[0], afterRise[0])
    }

    func test_scope_envelope_removes_dc_offset() {
        let n: UInt32 = 64
        var input = [Float](repeating: 0.5, count: Int(n))    // pure DC
        var out = [Float](repeating: 99, count: Int(n))
        input.withUnsafeBufferPointer { ip in
            out.withUnsafeMutableBufferPointer { op in
                vk_scope_envelope(ip.baseAddress, op.baseAddress, n, 1.0)
            }
        }
        // After DC removal, every sample should be near zero.
        let maxAbs = out.map { abs($0) }.max() ?? 0
        XCTAssertLessThan(maxAbs, 0.01)
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
