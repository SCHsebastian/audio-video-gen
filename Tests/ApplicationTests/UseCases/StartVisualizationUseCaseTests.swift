import XCTest
@testable import Application
@testable import Domain

final class StartVisualizationUseCaseTests: XCTestCase {

    func test_when_permission_denied_emits_waitingForPermission_and_stops() async {
        let cap = FakeSystemAudioCapturing()
        let ana = FakeAudioSpectrumAnalyzing()
        let perm = FakePermissionRequesting(); perm.state = .denied
        let r = FakeRenderer()
        let beat = FakeBeatDetecting()
        let sut = StartVisualizationUseCase(capture: cap, analyzer: ana, beats: beat, renderer: r, permissions: perm)
        let stream = await sut.execute(source: .systemWide)
        var seen: [VisualizationState] = []
        for await s in stream { seen.append(s); if seen.count == 1 { break } }
        XCTAssertEqual(seen.first, .waitingForPermission)
    }

    func test_when_granted_runs_pipeline_and_pushes_to_renderer() async {
        let cap = FakeSystemAudioCapturing()
        cap.frames = [AudioFrame(samples: Array(repeating: 0.1, count: 1024),
                                 sampleRate: SampleRate(hz: 48_000),
                                 timestamp: HostTime(machAbsolute: 1))]
        let ana = FakeAudioSpectrumAnalyzing()
        let perm = FakePermissionRequesting()
        let r = FakeRenderer()
        let beat = FakeBeatDetecting()
        let sut = StartVisualizationUseCase(capture: cap, analyzer: ana, beats: beat, renderer: r, permissions: perm)
        let stream = await sut.execute(source: .systemWide)
        var saw_running = false
        for await s in stream { if case .running = s { saw_running = true } }
        XCTAssertTrue(saw_running)
        XCTAssertEqual(ana.analyzeCount, 1)
        XCTAssertNotNil(r.lastSpectrum)
    }
}

final class FakeBeatDetecting: BeatDetecting, @unchecked Sendable {
    func feed(_ spectrum: SpectrumFrame) -> BeatEvent? { nil }
}
