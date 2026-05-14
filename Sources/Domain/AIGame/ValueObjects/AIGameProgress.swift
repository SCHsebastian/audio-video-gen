import Foundation

public struct AIGameProgress: Equatable, Sendable, Codable {
    public let id: UUID
    public let label: String
    public let createdAt: Date
    public let generation: Int
    public let bestFitness: Float
    public let genomes: [Genome]
    public let worldSeed: UInt64
    /// Stamp of `Genome.expectedLength` at save time. A future build that
    /// changes the NN topology refuses to load mismatched snapshots.
    public let genomeLength: Int

    public init(id: UUID, label: String, createdAt: Date,
                generation: Int, bestFitness: Float,
                genomes: [Genome], worldSeed: UInt64, genomeLength: Int) {
        self.id = id; self.label = label; self.createdAt = createdAt
        self.generation = generation; self.bestFitness = bestFitness
        self.genomes = genomes; self.worldSeed = worldSeed
        self.genomeLength = genomeLength
    }
}
