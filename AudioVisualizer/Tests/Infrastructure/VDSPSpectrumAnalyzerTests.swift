import XCTest
import Domain
@testable import AudioVisualizer

final class VDSPSpectrumAnalyzerTests: XCTestCase {
    func test_pure_sine_peaks_at_expected_band() {
        let sr: Double = 48_000
        let n = 1024
        let target: Double = 1000   // 1 kHz tone
        let samples: [Float] = (0..<n).map { i in
            Float(sin(2.0 * .pi * target * Double(i) / sr))
        }
        let sut = VDSPSpectrumAnalyzer(bandCount: 64, sampleRate: SampleRate(hz: sr), fftSize: n)
        let frame = AudioFrame(samples: samples, sampleRate: SampleRate(hz: sr), timestamp: .zero)
        let spectrum = sut.analyze(frame)
        XCTAssertEqual(spectrum.bands.count, 64)

        // 1 kHz in log-spaced 64 bands from 30 Hz to 16 kHz lies near index ~32.
        // Pick the argmax and assert it's in [28, 36].
        let maxIdx = spectrum.bands.enumerated().max(by: { $0.element < $1.element })!.offset
        XCTAssertTrue((28...36).contains(maxIdx), "expected 1 kHz peak near index 32, got \(maxIdx)")
        XCTAssertGreaterThan(spectrum.rms, 0.1)
    }

    func test_silence_returns_zeros_and_zero_rms() {
        let sut = VDSPSpectrumAnalyzer(bandCount: 64, sampleRate: SampleRate(hz: 48_000), fftSize: 1024)
        let frame = AudioFrame(samples: Array(repeating: 0, count: 1024),
                               sampleRate: SampleRate(hz: 48_000), timestamp: .zero)
        let s = sut.analyze(frame)
        XCTAssertEqual(s.rms, 0)
        XCTAssertEqual(s.bands.max() ?? 0, 0, accuracy: 1e-4)
    }
}
