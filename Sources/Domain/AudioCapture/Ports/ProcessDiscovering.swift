public protocol ProcessDiscovering: Sendable {
    func listAudioProcesses() async throws -> [AudioProcessInfo]
}
