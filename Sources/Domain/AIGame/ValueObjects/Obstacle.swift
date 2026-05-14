import Foundation

public struct Obstacle: Equatable, Sendable {
    public let xStart: Float
    public let width: Float
    public let height: Float
    public let kind: ObstacleKind

    public init(xStart: Float, width: Float, height: Float, kind: ObstacleKind) {
        self.xStart = xStart; self.width = width; self.height = height; self.kind = kind
    }

    public var xEnd: Float { xStart + width }
}
