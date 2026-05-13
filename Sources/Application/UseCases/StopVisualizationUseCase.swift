import Domain

public struct StopVisualizationUseCase: Sendable {
    private let capture: SystemAudioCapturing
    public init(capture: SystemAudioCapturing) { self.capture = capture }
    public func execute() async { await capture.stop() }
}
