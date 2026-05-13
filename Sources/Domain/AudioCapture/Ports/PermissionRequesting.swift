public enum PermissionState: Equatable, Sendable { case undetermined, granted, denied }

public protocol PermissionRequesting: Sendable {
    func current() async -> PermissionState
    func request() async -> PermissionState
}
