import Foundation

public enum AudioSource: Equatable, Hashable, Sendable {
    case systemWide
    case process(pid: pid_t, bundleID: String)
}
