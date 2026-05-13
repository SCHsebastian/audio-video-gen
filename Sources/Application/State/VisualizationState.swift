import Domain

public enum VisualizationState: Equatable, Sendable {
    case idle
    case waitingForPermission
    case running
    case noAudioYet
    case error(CaptureError)
}
