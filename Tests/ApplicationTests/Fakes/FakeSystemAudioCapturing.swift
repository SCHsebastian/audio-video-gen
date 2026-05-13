import Domain

final class FakeSystemAudioCapturing: SystemAudioCapturing, @unchecked Sendable {
    var frames: [AudioFrame] = []
    var startError: Error?
    private(set) var lastSource: AudioSource?
    private(set) var stopped = false

    func start(source: AudioSource) async throws -> AsyncStream<AudioFrame> {
        if let startError { throw startError }
        lastSource = source
        let (stream, continuation) = AsyncStream<AudioFrame>.makeStream()
        for f in frames { continuation.yield(f) }
        continuation.finish()
        return stream
    }

    func stop() async { stopped = true }
}
