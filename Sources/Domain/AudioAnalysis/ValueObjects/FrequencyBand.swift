public struct FrequencyBand: Equatable, Sendable {
    public let lowHz: Float; public let highHz: Float
    public init(lowHz: Float, highHz: Float) { self.lowHz = lowHz; self.highHz = highHz }
}
