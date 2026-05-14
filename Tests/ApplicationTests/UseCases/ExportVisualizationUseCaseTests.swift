import XCTest
@testable import Application
@testable import Domain

final class ExportVisualizationUseCaseTests: XCTestCase {

    private func makeFrame(_ value: Float = 0.1) -> AudioFrame {
        AudioFrame(samples: Array(repeating: value, count: 1024),
                   sampleRate: SampleRate(hz: 48_000),
                   timestamp: HostTime(machAbsolute: 1))
    }

    func test_when_decoder_yields_frames_renderer_consumes_each_video_step() async {
        // Three audio frames at 1024 samples / 48 kHz = 64 ms total audio. At 30
        // fps each video frame is 33.33 ms, so the loop crosses the step
        // boundary twice (≈ 21 ms / 43 ms / 64 ms vs 33 ms / 67 ms) and the
        // trailing drain check (audioTime > nextVideoTime - eps) is false at
        // 64 ms < 67 ms — so exactly 2 frames get rendered.
        let dec = FakeAudioFileDecoding()
        dec.frames = [makeFrame(), makeFrame(), makeFrame()]
        let ana = FakeAudioSpectrumAnalyzing()
        let beat = FakeBeatDetecting()
        let r = FakeOfflineVideoRendering()

        let sut = ExportVisualizationUseCase(decoder: dec, analyzer: ana, beats: beat, renderer: r)
        let options = RenderOptions.make(.hd720, .fps30)
        let stream = sut.execute(audio: URL(fileURLWithPath: "/tmp/in.wav"),
                                 output: URL(fileURLWithPath: "/tmp/out.mp4"),
                                 scene: .bars, palette: ColorPalette(name: "Test", stops: [.init(r: 0, g: 0, b: 0)]),
                                 options: options)
        var states: [ExportState] = []
        for await s in stream { states.append(s) }
        XCTAssertEqual(r.beginCalls.count, 1)
        XCTAssertEqual(r.beginCalls.first?.0, URL(fileURLWithPath: "/tmp/out.mp4"))
        XCTAssertEqual(r.consumedFrames, 2)
        XCTAssertEqual(r.finishCalls, 1)
        XCTAssertEqual(r.cancelCalls, 0)
        XCTAssertEqual(states.first, .preparing)
        if case .completed = states.last { } else { XCTFail("expected completed, got \(String(describing: states.last))") }
    }

    func test_when_decoder_throws_yields_failed_and_does_not_finish() async {
        let dec = FakeAudioFileDecoding()
        dec.decodeError = ExportError.fileUnreadable(URL(fileURLWithPath: "/x"), description: "nope")
        let r = FakeOfflineVideoRendering()
        let sut = ExportVisualizationUseCase(decoder: dec, analyzer: FakeAudioSpectrumAnalyzing(),
                                             beats: FakeBeatDetecting(), renderer: r)
        let stream = sut.execute(audio: URL(fileURLWithPath: "/x"),
                                 output: URL(fileURLWithPath: "/y.mp4"),
                                 scene: .bars,
                                 palette: ColorPalette(name: "T", stops: [.init(r: 0, g: 0, b: 0)]),
                                 options: .make(.hd720, .fps30))
        var sawFailed = false
        for await s in stream { if case .failed = s { sawFailed = true } }
        XCTAssertTrue(sawFailed)
        XCTAssertEqual(r.beginCalls.count, 0)
        XCTAssertEqual(r.finishCalls, 0)
    }

    func test_when_renderer_begin_throws_yields_failed_and_never_calls_consume() async {
        let dec = FakeAudioFileDecoding()
        dec.frames = [makeFrame()]
        let r = FakeOfflineVideoRendering()
        r.beginError = ExportError.outputUnwritable(URL(fileURLWithPath: "/x.mp4"), description: "denied")
        let sut = ExportVisualizationUseCase(decoder: dec, analyzer: FakeAudioSpectrumAnalyzing(),
                                             beats: FakeBeatDetecting(), renderer: r)
        let stream = sut.execute(audio: URL(fileURLWithPath: "/in.wav"),
                                 output: URL(fileURLWithPath: "/x.mp4"),
                                 scene: .bars,
                                 palette: ColorPalette(name: "T", stops: [.init(r: 0, g: 0, b: 0)]),
                                 options: .make(.hd720, .fps30))
        var sawFailed = false
        for await s in stream { if case .failed = s { sawFailed = true } }
        XCTAssertTrue(sawFailed)
        XCTAssertEqual(r.consumedFrames, 0)
        XCTAssertEqual(r.finishCalls, 0)
    }

    func test_progress_state_includes_total_when_decoder_knows_duration() async {
        let dec = FakeAudioFileDecoding()
        // 2 s of audio = 2 * 48000 = 96 000 audio frames → 60 fps × 2 s = 120 video frames.
        dec.estimatedTotal = 96_000
        // Feed enough audio frames to cross one full video second of output so
        // the use case emits at least one progress yield (which only fires
        // once per `fps` rendered video frames).
        dec.frames = Array(repeating: makeFrame(), count: 50)
        let sut = ExportVisualizationUseCase(decoder: dec, analyzer: FakeAudioSpectrumAnalyzing(),
                                             beats: FakeBeatDetecting(), renderer: FakeOfflineVideoRendering())
        let stream = sut.execute(audio: URL(fileURLWithPath: "/in.wav"),
                                 output: URL(fileURLWithPath: "/out.mp4"),
                                 scene: .bars,
                                 palette: ColorPalette(name: "T", stops: [.init(r: 0, g: 0, b: 0)]),
                                 options: .make(.hd720, .fps60))
        var lastTotal: Int?? = nil
        for await s in stream {
            if case .rendering(_, let total) = s { lastTotal = total }
        }
        XCTAssertEqual(lastTotal, .some(.some(120)))
    }

    func test_progress_state_total_is_nil_when_decoder_estimate_is_nil() async {
        let dec = FakeAudioFileDecoding()
        dec.estimatedTotal = nil
        dec.frames = Array(repeating: makeFrame(), count: 50)
        let sut = ExportVisualizationUseCase(decoder: dec, analyzer: FakeAudioSpectrumAnalyzing(),
                                             beats: FakeBeatDetecting(), renderer: FakeOfflineVideoRendering())
        let stream = sut.execute(audio: URL(fileURLWithPath: "/in.wav"),
                                 output: URL(fileURLWithPath: "/out.mp4"),
                                 scene: .bars,
                                 palette: ColorPalette(name: "T", stops: [.init(r: 0, g: 0, b: 0)]),
                                 options: .make(.hd720, .fps60))
        var sawNilTotal = false
        for await s in stream {
            if case .rendering(_, let total) = s, total == nil { sawNilTotal = true }
        }
        XCTAssertTrue(sawNilTotal)
    }
}
