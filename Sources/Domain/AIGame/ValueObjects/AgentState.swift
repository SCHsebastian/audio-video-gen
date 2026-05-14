import Foundation

public struct AgentState: Equatable, Sendable {
    public var posX: Float
    public var posY: Float
    public var velY: Float
    public var alive: Bool
    public var fitness: Float
    public let colorSeed: Float    // [0, 1] — palette sample u

    public init(posX: Float, posY: Float, velY: Float,
                alive: Bool, fitness: Float, colorSeed: Float) {
        self.posX = posX; self.posY = posY; self.velY = velY
        self.alive = alive; self.fitness = fitness; self.colorSeed = colorSeed
    }

    /// Standard spawn: at world origin, on the ground, alive, zero fitness.
    public static func spawn(colorSeed: Float) -> AgentState {
        AgentState(posX: 0, posY: 0, velY: 0, alive: true, fitness: 0,
                   colorSeed: colorSeed)
    }
}
