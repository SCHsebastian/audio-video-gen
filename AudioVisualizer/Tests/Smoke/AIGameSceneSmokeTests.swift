import XCTest
@testable import AudioVisualizer
import Domain

final class AIGameSceneSmokeTests: XCTestCase {
    func test_renderer_can_build_aigame_scene_without_throwing() throws {
        let r = try MetalVisualizationRenderer.make()
        // Switching to .aigame must trigger a successful materialize on next
        // consume(). Push a single zero frame to provoke build.
        r.setScene(.aigame)
        let zero = SpectrumFrame(bands: Array(repeating: 0, count: 64),
                                 rms: 0, timestamp: .zero)
        let wav = WaveformBuffer(mono: Array(repeating: 0, count: 1024))
        r.consume(spectrum: zero, waveform: wav, beat: nil)
        // If we got here without throwing, the scene built and consumed one frame.
        XCTAssertTrue(true)
    }
}
