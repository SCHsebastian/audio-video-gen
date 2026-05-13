public struct BeatEvent: Equatable, Sendable {
    public let timestamp: HostTime
    public let strength: Float

    // Tempo context. Both are 0 when unknown (first beat / no stable tempo yet).
    public let interval: Float   // seconds since the previous beat
    public let bpm: Float        // smoothed BPM estimate, clamped to a sane range

    public init(timestamp: HostTime, strength: Float, interval: Float = 0, bpm: Float = 0) {
        self.timestamp = timestamp
        self.strength = strength
        self.interval = interval
        self.bpm = bpm
    }
}
