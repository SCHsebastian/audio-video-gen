public struct ColorPalette: Equatable, Hashable, Sendable {
    public let name: String
    public let stops: [RGB]
    public init(name: String, stops: [RGB]) { self.name = name; self.stops = stops }
}
