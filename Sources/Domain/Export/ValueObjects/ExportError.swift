import Foundation

/// Domain-level errors surfaced through `ExportVisualizationUseCase`'s state
/// stream. Each case carries enough context for the toolbar progress chip's
/// tooltip without leaking AVFoundation types into Domain — the underlying
/// platform error is captured as a `String` description.
public enum ExportError: Error, Equatable, Sendable {
    case fileUnreadable(URL, description: String)
    case unsupportedAudioFormat(description: String)
    case outputUnwritable(URL, description: String)
    case encoderFailed(description: String)
    case metalUnavailable
}
