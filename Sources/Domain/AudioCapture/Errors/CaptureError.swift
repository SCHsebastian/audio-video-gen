import Foundation

public enum CaptureError: Error, Equatable, Sendable {
    case permissionDenied
    case permissionUndetermined
    case processNotFound(pid_t)
    case processNotFoundByBundleID(String)
    case formatUnsupported(description: String)
    case tapCreationFailed(OSStatus)
    case aggregateDeviceCreationFailed(OSStatus)
    case ioProcStartFailed(OSStatus)
    case defaultOutputDeviceUnavailable
}
