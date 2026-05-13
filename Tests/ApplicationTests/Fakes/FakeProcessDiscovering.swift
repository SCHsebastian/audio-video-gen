import Domain

final class FakeProcessDiscovering: ProcessDiscovering, @unchecked Sendable {
    var stub: [AudioProcessInfo] = []
    var error: Error?
    func listAudioProcesses() async throws -> [AudioProcessInfo] {
        if let error { throw error }
        return stub
    }
}
