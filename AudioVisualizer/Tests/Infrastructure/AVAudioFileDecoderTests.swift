import XCTest
import AVFoundation
import Domain
@testable import AudioVisualizer

final class AVAudioFileDecoderTests: XCTestCase {
    private var tempURLs: [URL] = []

    override func tearDown() async throws {
        for url in tempURLs {
            try? FileManager.default.removeItem(at: url)
        }
        tempURLs.removeAll()
        try await super.tearDown()
    }

    func test_decodes_known_wav_to_expected_frame_count() async throws {
        let url = makeTempURL()
        try writeSineWAV(to: url, sampleRate: 48_000, channels: 1, frequency: 440, durationSeconds: 1.0)

        let sut = AVAudioFileDecoder()
        let frames = try await collectAllFrames(from: try sut.decode(url: url))
        let totalSamples = frames.reduce(0) { $0 + $1.samples.count }

        XCTAssertEqual(totalSamples, 48_128, "expected ~48_000 samples padded to next 1024 boundary, got \(totalSamples)")
        XCTAssertTrue(abs(totalSamples - 48_000) <= 1024, "total samples must be within one chunk of 48_000")
        for frame in frames {
            XCTAssertEqual(frame.samples.count, 1024)
            XCTAssertEqual(frame.left.count, 1024)
            XCTAssertEqual(frame.right.count, 1024)
            XCTAssertEqual(frame.sampleRate.hz, 48_000)
        }
    }

    func test_resamples_44_1kHz_source_to_48kHz() async throws {
        let url = makeTempURL()
        try writeSineWAV(to: url, sampleRate: 44_100, channels: 1, frequency: 440, durationSeconds: 1.0)

        let sut = AVAudioFileDecoder()
        let frames = try await collectAllFrames(from: try sut.decode(url: url))
        let totalSamples = frames.reduce(0) { $0 + $1.samples.count }

        XCTAssertTrue(abs(totalSamples - 48_000) <= 1024,
                      "expected ~48_000 after resample from 44.1k, got \(totalSamples)")
    }

    func test_yields_mono_mixdown_matching_l_r_average() async throws {
        let url = makeTempURL()
        // Constant L=+0.5, R=-0.5 stereo — mono mixdown should be 0 for every sample.
        try writeConstantStereoWAV(to: url, sampleRate: 48_000, left: 0.5, right: -0.5, frames: 4096)

        let sut = AVAudioFileDecoder()
        let frames = try await collectAllFrames(from: try sut.decode(url: url))
        XCTAssertFalse(frames.isEmpty)
        let first = frames[0]
        XCTAssertEqual(first.samples.count, 1024)
        for sample in first.samples {
            XCTAssertEqual(sample, 0.0, accuracy: 1e-4, "mono mixdown of L=0.5 and R=-0.5 should be 0")
        }
    }

    func test_throws_on_nonexistent_file() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        let sut = AVAudioFileDecoder()
        var didThrow = false
        do {
            for try await _ in try sut.decode(url: url) {}
        } catch {
            didThrow = true
        }
        XCTAssertTrue(didThrow, "decoding a nonexistent file must throw")
    }

    func test_estimated_frame_count_returns_close_to_actual() async throws {
        let url = makeTempURL()
        try writeSineWAV(to: url, sampleRate: 48_000, channels: 1, frequency: 440, durationSeconds: 0.5)
        let sut = AVAudioFileDecoder()
        let estimate = try await sut.estimatedFrameCount(url: url)
        XCTAssertNotNil(estimate)
        XCTAssertTrue(abs((estimate ?? 0) - 24_000) <= 1024,
                      "expected ~24_000 frames for 0.5 s, got \(estimate ?? -1)")
    }

    // MARK: - Helpers

    private func makeTempURL() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        tempURLs.append(url)
        return url
    }

    private func collectAllFrames(from stream: AsyncThrowingStream<AudioFrame, Error>) async throws -> [AudioFrame] {
        var out: [AudioFrame] = []
        for try await frame in stream { out.append(frame) }
        return out
    }

    /// Write a WAV file containing a sine wave at the given rate / channel count.
    /// Channels >= 2 duplicate the same tone into both channels.
    private func writeSineWAV(to url: URL, sampleRate: Double, channels: UInt32, frequency: Double, durationSeconds: Double) throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: sampleRate,
                                   channels: AVAudioChannelCount(channels),
                                   interleaved: false)!
        let frameCount = AVAudioFrameCount(sampleRate * durationSeconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        let twoPi = 2.0 * Double.pi
        for ch in 0..<Int(channels) {
            let p = buffer.floatChannelData![ch]
            for i in 0..<Int(frameCount) {
                p[i] = Float(sin(twoPi * frequency * Double(i) / sampleRate))
            }
        }
        let file = try AVAudioFile(forWriting: url,
                                   settings: format.settings,
                                   commonFormat: .pcmFormatFloat32,
                                   interleaved: false)
        try file.write(from: buffer)
    }

    /// Write a stereo WAV file with constant L and R sample values.
    private func writeConstantStereoWAV(to url: URL, sampleRate: Double, left: Float, right: Float, frames: Int) throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: sampleRate,
                                   channels: 2,
                                   interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        let pL = buffer.floatChannelData![0]
        let pR = buffer.floatChannelData![1]
        for i in 0..<frames {
            pL[i] = left
            pR[i] = right
        }
        let file = try AVAudioFile(forWriting: url,
                                   settings: format.settings,
                                   commonFormat: .pcmFormatFloat32,
                                   interleaved: false)
        try file.write(from: buffer)
    }
}
