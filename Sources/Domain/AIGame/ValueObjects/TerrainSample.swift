import Foundation

public struct TerrainSample: Equatable, Sendable {
    public let x: Float
    public let y: Float
    public init(x: Float, y: Float) { self.x = x; self.y = y }
}
