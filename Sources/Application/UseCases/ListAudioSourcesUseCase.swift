import Domain

public struct ListAudioSourcesUseCase: Sendable {
    private let discovery: ProcessDiscovering
    public init(discovery: ProcessDiscovering) { self.discovery = discovery }
    public func execute() async throws -> [AudioSource] {
        let procs = try await discovery.listAudioProcesses()
        return [.systemWide] + procs.map { .process(pid: $0.pid, bundleID: $0.bundleID) }
    }
}
