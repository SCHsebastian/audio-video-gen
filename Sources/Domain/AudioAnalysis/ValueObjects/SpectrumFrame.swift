public struct SpectrumFrame: Equatable, Sendable {
    public let bands: [Float]    // normalized 0..1
    public let rms: Float        // overall loudness 0..1
    public let timestamp: HostTime
    public init(bands: [Float], rms: Float, timestamp: HostTime) {
        self.bands = bands; self.rms = rms; self.timestamp = timestamp
    }
}
