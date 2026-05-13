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

    func test_bars_process_log_rebins_and_holds_peaks() {
        // 64 linear FFT bands at 48 kHz capture; the kernel produces 32 log bars.
        let inCount: UInt32 = 64
        let outCount: UInt32 = 32
        let sampleRate: Float = 48000

        var input = [Float](repeating: 0, count: Int(inCount))
        // Excite a mid-band bin so a single log bar should light up.
        input[20] = 0.8

        var out   = [Float](repeating: 0, count: Int(outCount))
        var peaks = [Float](repeating: 0, count: Int(outCount))
        var state = [Float](repeating: 0, count: Int(outCount) * 2)

        // Drive several frames so the attack catches up to the excited band.
        for _ in 0..<10 {
            input.withUnsafeBufferPointer { ip in
                out.withUnsafeMutableBufferPointer { op in
                    state.withUnsafeMutableBufferPointer { sp in
                        peaks.withUnsafeMutableBufferPointer { pp in
                            vk_bars_process(ip.baseAddress, inCount,
                                            op.baseAddress, outCount,
                                            sp.baseAddress, pp.baseAddress,
                                            sampleRate, 0.016)
                        }
                    }
                }
            }
        }

        // At least one log bar must register the excited input bin.
        XCTAssertGreaterThan(out.max() ?? 0, 0.20)
        // Peak cap should sit at or above the live bar for every bar.
        for i in 0..<Int(outCount) {
            XCTAssertGreaterThanOrEqual(peaks[i], out[i] - 1e-3)
        }
    }

    func test_bars_process_decays_with_slow_release() {
        let inCount: UInt32 = 64
        let outCount: UInt32 = 16
        var hi    = [Float](repeating: 0.6, count: Int(inCount))
        var zero  = [Float](repeating: 0,   count: Int(inCount))
        var out   = [Float](repeating: 0,   count: Int(outCount))
        var peaks = [Float](repeating: 0,   count: Int(outCount))
        var state = [Float](repeating: 0,   count: Int(outCount) * 2)

        // Drive high to settle.
        for _ in 0..<20 {
            hi.withUnsafeBufferPointer { ip in
                out.withUnsafeMutableBufferPointer { op in
                    state.withUnsafeMutableBufferPointer { sp in
                        peaks.withUnsafeMutableBufferPointer { pp in
                            vk_bars_process(ip.baseAddress, inCount,
                                            op.baseAddress, outCount,
                                            sp.baseAddress, pp.baseAddress,
                                            48000, 0.016)
                        }
                    }
                }
            }
        }
        let afterRise = (out.max() ?? 0)
        XCTAssertGreaterThan(afterRise, 0.30)

        // Now drop to silence for 3 frames; with τ_rel ≈ 300 ms the bar should
        // still be well above 30% of its peak.
        for _ in 0..<3 {
            zero.withUnsafeBufferPointer { ip in
                out.withUnsafeMutableBufferPointer { op in
                    state.withUnsafeMutableBufferPointer { sp in
                        peaks.withUnsafeMutableBufferPointer { pp in
                            vk_bars_process(ip.baseAddress, inCount,
                                            op.baseAddress, outCount,
                                            sp.baseAddress, pp.baseAddress,
                                            48000, 0.016)
                        }
                    }
                }
            }
        }
        XCTAssertGreaterThan(out.max() ?? 0, afterRise * 0.5)
        XCTAssertLessThan(out.max() ?? 0, afterRise)
    }

    func test_scope_prepare_centres_on_zero_crossing() {
        let inCount: UInt32 = 1024
        let outCount: UInt32 = 512
        // A pure 200-Hz sine at 48 kHz so the first positive zero-crossing past
        // sample 256 sits at a predictable index.
        var input = [Float](repeating: 0, count: Int(inCount))
        for i in 0..<Int(inCount) {
            input[i] = sinf(2.0 * .pi * 200.0 * Float(i) / 48000.0)
        }
        var out = [Float](repeating: 0, count: Int(outCount))
        input.withUnsafeBufferPointer { ip in
            out.withUnsafeMutableBufferPointer { op in
                vk_scope_prepare(ip.baseAddress, inCount, op.baseAddress, outCount, 1.0)
            }
        }
        // First sample of the slice should be near zero (we just crossed) and the
        // signal should immediately rise — that's positive-slope trigger.
        XCTAssertLessThan(abs(out[0]), 0.30)
        XCTAssertGreaterThan(out[10] - out[0], 0.0)
    }

    func test_catmull_rom_passes_through_control_points() {
        // 4 control points in a line.
        var input: [Float] = [0, 0,   0.25, 0.25,   0.5, 0.5,   0.75, 0.75]
        let subdiv: UInt32 = 8
        // Output size = (inCount-3)*subdiv + 1 = (4-3)*8 + 1 = 9 pairs.
        var out = [Float](repeating: 0, count: 9 * 2)
        input.withUnsafeBufferPointer { ip in
            out.withUnsafeMutableBufferPointer { op in
                vk_catmull_rom(ip.baseAddress, 4, op.baseAddress, subdiv)
            }
        }
        // First sample = P1 (the start of the active span between P1..P2).
        XCTAssertEqual(out[0], 0.25, accuracy: 1e-4)
        XCTAssertEqual(out[1], 0.25, accuracy: 1e-4)
        // Last sample = P2 (the trailing endpoint we explicitly wrote).
        XCTAssertEqual(out.dropLast(0).suffix(2).first ?? -1, 0.5,  accuracy: 1e-4)
        XCTAssertEqual(out.last ?? -1, 0.5, accuracy: 1e-4)
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
