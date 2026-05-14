import Foundation

public struct PopulationSnapshot: Equatable, Sendable {
    public let agents: [AgentState]
    public let obstacles: [Obstacle]
    public let terrainSamples: [TerrainSample]
    public let cameraX: Float
    public let generation: Int
    public let bestFitness: Float
    public let aliveCount: Int

    public init(agents: [AgentState], obstacles: [Obstacle],
                terrainSamples: [TerrainSample], cameraX: Float,
                generation: Int, bestFitness: Float, aliveCount: Int) {
        self.agents = agents; self.obstacles = obstacles
        self.terrainSamples = terrainSamples; self.cameraX = cameraX
        self.generation = generation; self.bestFitness = bestFitness
        self.aliveCount = aliveCount
    }
}
