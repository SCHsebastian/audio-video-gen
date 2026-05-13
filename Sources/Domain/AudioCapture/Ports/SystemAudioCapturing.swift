public protocol SystemAudioCapturing: Sendable {
    func start(source: AudioSource) async throws -> AsyncStream<AudioFrame>
    func stop() async
}
