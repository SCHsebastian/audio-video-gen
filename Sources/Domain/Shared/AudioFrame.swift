public struct AudioFrame: Equatable, Sendable {
    public let samples: [Float]                 // mono mixdown — always populated
    public let left: [Float]                    // L channel, parallel-indexed; empty when source is mono
    public let right: [Float]                   // R channel, parallel-indexed; empty when source is mono
    public let sampleRate: SampleRate
    public let timestamp: HostTime
    public init(samples: [Float], sampleRate: SampleRate, timestamp: HostTime,
                left: [Float] = [], right: [Float] = []) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.timestamp = timestamp
        self.left = left
        self.right = right
    }
}
