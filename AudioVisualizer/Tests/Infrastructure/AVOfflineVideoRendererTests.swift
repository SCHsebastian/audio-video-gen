import XCTest
import AVFoundation
import Metal
import Domain
@testable import AudioVisualizer

final class AVOfflineVideoRendererTests: XCTestCase {

    private func makeRendererOrSkip() throws -> (AVOfflineVideoRenderer, MTLDevice) {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("No Metal device available")
        }
        guard let queue = device.makeCommandQueue() else {
            throw XCTSkip("Cannot create command queue")
        }
        guard let library = device.makeDefaultLibrary() else {
            throw XCTSkip("No default Metal library available")
        }
        let renderer = MetalVisualizationRenderer.makeOfflineRenderer(
            device: device, queue: queue, library: library)
        return (renderer, device)
    }

    private func tempOutputURL(_ name: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
        return dir.appendingPathComponent("AVOfflineVideoRendererTests-\(name)-\(UUID().uuidString).mp4")
    }

    private func silentSpectrum() -> SpectrumFrame {
        SpectrumFrame(bands: Array(repeating: 0, count: 64), rms: 0, timestamp: .zero)
    }

    private func silentWaveform() -> WaveformBuffer {
        WaveformBuffer(mono: Array(repeating: 0, count: 1024))
    }

    func test_renders_one_second_of_silence_to_existing_file() async throws {
        let (renderer, _) = try makeRendererOrSkip()
        let url = tempOutputURL("silence")
        defer { try? FileManager.default.removeItem(at: url) }

        let options = RenderOptions.make(.hd720, .fps30)
        try renderer.begin(output: url, options: options, scene: .bars, palette: PaletteFactory.xpNeon)

        let spectrum = silentSpectrum()
        let waveform = silentWaveform()
        let dt = Float(1.0 / 30.0)
        for _ in 0..<30 {
            try await renderer.consume(spectrum: spectrum, waveform: waveform, beat: nil, dt: dt)
        }
        let finalURL = try await renderer.finish()
        XCTAssertEqual(finalURL, url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        let asset = AVURLAsset(url: url)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(videoTracks.count, 1)
        XCTAssertEqual(audioTracks.count, 0)

        let track = videoTracks[0]
        let naturalSize = try await track.load(.naturalSize)
        XCTAssertEqual(Int(naturalSize.width), 1280)
        XCTAssertEqual(Int(naturalSize.height), 720)

        let duration = try await asset.load(.duration)
        let seconds = CMTimeGetSeconds(duration)
        XCTAssertEqual(seconds, 1.0, accuracy: 0.1)
    }

    func test_cancel_deletes_partial_file() async throws {
        let (renderer, _) = try makeRendererOrSkip()
        let url = tempOutputURL("cancel")
        defer { try? FileManager.default.removeItem(at: url) }

        let options = RenderOptions.make(.hd720, .fps30)
        try renderer.begin(output: url, options: options, scene: .bars, palette: PaletteFactory.xpNeon)

        let spectrum = silentSpectrum()
        let waveform = silentWaveform()
        let dt = Float(1.0 / 30.0)
        for _ in 0..<5 {
            try await renderer.consume(spectrum: spectrum, waveform: waveform, beat: nil, dt: dt)
        }
        await renderer.cancel()

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}
