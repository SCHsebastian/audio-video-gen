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
        XCTAssertEqual(s.bass, 0, accuracy: 1e-4)
        XCTAssertEqual(s.mid, 0, accuracy: 1e-4)
        XCTAssertEqual(s.treble, 0, accuracy: 1e-4)
        XCTAssertEqual(s.centroid, 0, accuracy: 1e-4)
        XCTAssertEqual(s.flux, 0, accuracy: 1e-4)
    }

    func test_bass_heavy_tone_lights_up_bass_band() {
        // 80 Hz sine — squarely inside the bass sub-band (0..bandCount/8).
        let sr: Double = 48_000
        let n = 1024
        let samples: [Float] = (0..<n).map { i in Float(sin(2.0 * .pi * 80.0 * Double(i) / sr)) }
        let sut = VDSPSpectrumAnalyzer(bandCount: 64, sampleRate: SampleRate(hz: sr), fftSize: n)
        let s = sut.analyze(AudioFrame(samples: samples, sampleRate: SampleRate(hz: sr), timestamp: .zero))
        XCTAssertGreaterThan(s.bass, s.mid, "80 Hz tone should push bass above mid")
        XCTAssertGreaterThan(s.bass, s.treble, "80 Hz tone should push bass above treble")
        XCTAssertLessThan(s.centroid, 0.30, "centroid for a low tone should sit in the lower third")
    }

    func test_treble_heavy_tone_lights_up_treble_band_and_centroid() {
        // 8 kHz sine — well inside the treble sub-band (bandCount/2..bandCount).
        let sr: Double = 48_000
        let n = 1024
        let samples: [Float] = (0..<n).map { i in Float(sin(2.0 * .pi * 8_000.0 * Double(i) / sr)) }
        let sut = VDSPSpectrumAnalyzer(bandCount: 64, sampleRate: SampleRate(hz: sr), fftSize: n)
        let s = sut.analyze(AudioFrame(samples: samples, sampleRate: SampleRate(hz: sr), timestamp: .zero))
        XCTAssertGreaterThan(s.treble, s.bass, "8 kHz tone should push treble above bass")
        XCTAssertGreaterThan(s.centroid, 0.70, "centroid for a bright tone should be in the upper third")
    }

    func test_mono_frames_leave_left_and_right_bands_empty() {
        let sut = VDSPSpectrumAnalyzer(bandCount: 64, sampleRate: SampleRate(hz: 48_000), fftSize: 1024)
        let samples = Array<Float>(repeating: 0, count: 1024)
        let f = AudioFrame(samples: samples, sampleRate: SampleRate(hz: 48_000), timestamp: .zero)
        let s = sut.analyze(f)
        XCTAssertTrue(s.leftBands.isEmpty, "mono input must not produce leftBands")
        XCTAssertTrue(s.rightBands.isEmpty, "mono input must not produce rightBands")
    }

    func test_stereo_frames_produce_distinct_left_and_right_bands() {
        // L: 80 Hz sine, R: 8 kHz sine — the two channels should peak in very
        // different bands.
        let sr: Double = 48_000
        let n = 1024
        let left:  [Float] = (0..<n).map { i in Float(sin(2.0 * .pi * 80.0    * Double(i) / sr)) }
        let right: [Float] = (0..<n).map { i in Float(sin(2.0 * .pi * 8_000.0 * Double(i) / sr)) }
        let mono:  [Float] = zip(left, right).map { ($0 + $1) * 0.5 }
        let sut = VDSPSpectrumAnalyzer(bandCount: 64, sampleRate: SampleRate(hz: sr), fftSize: n)
        let s = sut.analyze(AudioFrame(samples: mono,
                                       sampleRate: SampleRate(hz: sr),
                                       timestamp: .zero,
                                       left: left, right: right))
        XCTAssertEqual(s.leftBands.count, 64)
        XCTAssertEqual(s.rightBands.count, 64)
        let lMax = s.leftBands.enumerated().max(by: { $0.element < $1.element })!.offset
        let rMax = s.rightBands.enumerated().max(by: { $0.element < $1.element })!.offset
        XCTAssertLessThan(lMax, 16, "80 Hz tone should peak in the bass region of leftBands")
        XCTAssertGreaterThan(rMax, 48, "8 kHz tone should peak in the treble region of rightBands")
    }

    func test_spectral_flux_fires_on_onset_then_settles() {
        // Silence first frame, loud onset on the second — flux should jump up
        // on the onset and then drop back down on a sustained third frame.
        let sr: Double = 48_000
        let n = 1024
        let sut = VDSPSpectrumAnalyzer(bandCount: 64, sampleRate: SampleRate(hz: sr), fftSize: n)
        let silence = Array<Float>(repeating: 0, count: n)
        let tone: [Float] = (0..<n).map { i in Float(sin(2.0 * .pi * 1_000.0 * Double(i) / sr)) }
        _ = sut.analyze(AudioFrame(samples: silence, sampleRate: SampleRate(hz: sr), timestamp: .zero))
        let onset = sut.analyze(AudioFrame(samples: tone, sampleRate: SampleRate(hz: sr), timestamp: .zero))
        let sustain = sut.analyze(AudioFrame(samples: tone, sampleRate: SampleRate(hz: sr), timestamp: .zero))
        XCTAssertGreaterThan(onset.flux, 0.0, "flux must rise on the onset frame")
        XCTAssertGreaterThan(onset.flux, sustain.flux, "flux must drop once the spectrum stops growing")
    }
}
