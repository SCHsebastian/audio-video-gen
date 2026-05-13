public struct BeatEvent: Equatable, Sendable {
    public let timestamp: HostTime; public let strength: Float
    public init(timestamp: HostTime, strength: Float) {
        self.timestamp = timestamp; self.strength = strength
    }
}
