import Foundation

public final class Population {
    public let size: Int
    private let source: RandomSource
    public private(set) var worldSeed: UInt64

    private var world: World
    private var genomes: [Genome]
    private var networks: [NeuralNetwork]
    private var agents: [AgentState]
    private var jumpLatches: [Bool]
    private(set) public var generation: Int = 1
    private var bestFitness: Float = 0

    public var onGenerationDidIncrement: ((Int) -> Void)?

    public init(size: Int, seed: UInt64, source: RandomSource) {
        self.size = size
        self.source = source
        self.worldSeed = seed
        self.world = World(seed: seed, source: source)
        self.genomes = []
        self.networks = []
        self.agents = []
        self.jumpLatches = []
        seedFreshGenomes()
    }

    public convenience init(restoring snapshot: AIGameProgress,
                            source: RandomSource) {
        precondition(snapshot.genomes.count > 0)
        self.init(size: snapshot.genomes.count,
                  seed: snapshot.worldSeed,
                  source: source)
        self.genomes = snapshot.genomes
        self.networks = snapshot.genomes.map { try! NeuralNetwork(genome: $0) }
        self.agents = (0..<snapshot.genomes.count).map { i in
            AgentState.spawn(colorSeed: Float(i) / Float(snapshot.genomes.count))
        }
        self.jumpLatches = Array(repeating: false, count: snapshot.genomes.count)
        self.generation = snapshot.generation
        self.bestFitness = snapshot.bestFitness
    }

    public func step(dt: Float, audio: AudioDrive) -> PopulationSnapshot {
        world.advance(dt: dt, audio: audio)
        for i in 0..<size {
            let next = Agent.step(state: agents[i], world: world,
                                  nn: networks[i], dt: dt,
                                  jumpHeld: &jumpLatches[i], audio: audio)
            agents[i] = next
            if next.fitness > bestFitness { bestFitness = next.fitness }
        }
        if alive == 0 { evolve() }
        return snapshot()
    }

    public func snapshot() -> PopulationSnapshot {
        PopulationSnapshot(
            agents: agents, obstacles: world.obstacles,
            terrainSamples: world.terrainSamples(), cameraX: world.cameraX,
            generation: generation, bestFitness: bestFitness, aliveCount: alive
        )
    }

    public func snapshotProgress(label: String) -> AIGameProgress {
        AIGameProgress(
            id: UUID(), label: label, createdAt: Date(),
            generation: generation, bestFitness: bestFitness,
            genomes: genomes, worldSeed: worldSeed,
            genomeLength: Genome.expectedLength
        )
    }

    /// Hard reset: new generation 1 with fresh random genomes and a fresh world.
    public func randomize() {
        generation = 1
        bestFitness = 0
        world = World(seed: worldSeed &+ UInt64.random(in: 1...10_000),
                      source: source)
        seedFreshGenomes()
    }

    // MARK: testing hooks
    public func killAllForTesting() {
        for i in 0..<size { agents[i].alive = false }
    }

    // MARK: privates
    private var alive: Int { agents.lazy.filter { $0.alive }.count }

    private func seedFreshGenomes() {
        genomes = (0..<size).map { _ in Genome.random(using: source) }
        networks = genomes.map { try! NeuralNetwork(genome: $0) }
        agents = (0..<size).map { i in
            AgentState.spawn(colorSeed: Float(i) / Float(size))
        }
        jumpLatches = Array(repeating: false, count: size)
    }

    private func evolve() {
        let ranked = zip(agents, genomes).sorted { $0.0.fitness > $1.0.fitness }
        let eliteA = ranked[0].1
        let eliteB = ranked[min(1, ranked.count - 1)].1
        var next: [Genome] = [eliteA, eliteB]
        while next.count < size {
            let child = GeneticEvolver.crossover(eliteA, eliteB, using: source)
            next.append(GeneticEvolver.mutate(child, rate: 0.10, sigma: 0.25,
                                              using: source))
        }
        genomes = next
        networks = genomes.map { try! NeuralNetwork(genome: $0) }
        agents = (0..<size).map { i in
            // Inherit color seed from rank order so ancestry reads visually.
            AgentState.spawn(colorSeed: Float(i) / Float(size))
        }
        jumpLatches = Array(repeating: false, count: size)
        generation += 1
        onGenerationDidIncrement?(generation)
    }
}
