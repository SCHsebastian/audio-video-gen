import Domain

final class FakePermissionRequesting: PermissionRequesting, @unchecked Sendable {
    var state: PermissionState = .granted
    func current() async -> PermissionState { state }
    func request() async -> PermissionState { state }
}
