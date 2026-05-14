import Domain
import Foundation

final class FakeOfflineVideoRendering: OfflineVideoRendering, @unchecked Sendable {
    var beginError: Error?
    var consumeError: Error?
    var finishError: Error?
    var finishURLOverride: URL?

    private(set) var beginCalls: [(URL, RenderOptions, SceneKind, String)] = []
    private(set) var beginAIGameProgress: [AIGameProgress?] = []
    private(set) var consumedFrames = 0
    private(set) var finishCalls = 0
    private(set) var cancelCalls = 0

    func begin(output: URL, options: RenderOptions, scene: SceneKind,
               palette: ColorPalette,
               aiGameProgress: AIGameProgress?) throws {
        if let e = beginError { throw e }
        beginCalls.append((output, options, scene, palette.name))
        beginAIGameProgress.append(aiGameProgress)
    }

    func consume(spectrum: SpectrumFrame, waveform: WaveformBuffer, beat: BeatEvent?, dt: Float) async throws {
        if let e = consumeError { throw e }
        consumedFrames += 1
    }

    func finish() async throws -> URL {
        finishCalls += 1
        if let e = finishError { throw e }
        return finishURLOverride ?? beginCalls.last?.0 ?? URL(fileURLWithPath: "/dev/null")
    }

    func cancel() async {
        cancelCalls += 1
    }
}
