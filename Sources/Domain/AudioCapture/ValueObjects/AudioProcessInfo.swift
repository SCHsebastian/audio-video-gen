import Foundation

public struct AudioProcessInfo: Equatable, Hashable, Sendable {
    public let pid: pid_t
    public let bundleID: String
    public let displayName: String
    public let isProducingAudio: Bool
    public init(pid: pid_t, bundleID: String, displayName: String, isProducingAudio: Bool) {
        self.pid = pid; self.bundleID = bundleID
        self.displayName = displayName; self.isProducingAudio = isProducingAudio
    }
}
