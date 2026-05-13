public struct AudioFrame: Equatable, Sendable {
    public let samples: [Float]                 // mono mixdown
    public let sampleRate: SampleRate
    public let timestamp: HostTime
    public init(samples: [Float], sampleRate: SampleRate, timestamp: HostTime) {
        self.samples = samples; self.sampleRate = sampleRate; self.timestamp = timestamp
    }
}
