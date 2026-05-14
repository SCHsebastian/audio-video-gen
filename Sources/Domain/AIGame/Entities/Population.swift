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

    /// Sim-time threshold past which the jumpBoost effect expires. 0 = no boost.
    public private(set) var jumpBoostUntilSimTime: Float = 0
    public private(set) var simTime: Float = 0

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
        simTime += dt
        world.advance(dt: dt, audio: audio)
        let jumpMul: Float = (simTime < jumpBoostUntilSimTime) ? 1.5 : 1.0
        for i in 0..<size {
            let next = Agent.step(state: agents[i], world: world,
                                  nn: networks[i], dt: dt,
                                  jumpHeld: &jumpLatches[i], audio: audio,
                                  jumpImpulseMultiplier: jumpMul)
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

    // MARK: events (Task 7.2)

    public func applyEvent(_ event: AIGameEvent, source r: RandomSource) {
        switch event {
        case .catastrophicMutation:
            for i in 0..<size where agents[i].alive {
                genomes[i] = GeneticEvolver.mutate(genomes[i],
                                                  rate: 1.0, sigma: 0.5,
                                                  using: r)
                networks[i] = try! NeuralNetwork(genome: genomes[i])
            }
        case .cull:
            let aliveIdx = (0..<size).filter { agents[$0].alive }
            let killCount = aliveIdx.count / 2
            let toKill = Array(aliveIdx.shuffled().prefix(killCount))
            for i in toKill { agents[i].alive = false }
        case .jumpBoost:
            jumpBoostUntilSimTime = simTime + 5.0
        case .earthquake:
            world.reseedTerrainAndClearObstacles(newSeed: worldSeed &+ 7919)
            worldSeed = worldSeed &+ 7919
        case .bonusObstacleWave:
            for k in 0..<3 {
                let dx = 1.4 + Float(k) * 0.3
                world.appendForcedObstacle(
                    Obstacle(xStart: world.cameraX + dx, width: 0.12,
                             height: 0.25, kind: .spike)
                )
            }
        case .lineageSwap:
            let donor = donorGenomeForLineageSwap()
            for i in 0..<size where agents[i].alive {
                genomes[i] = GeneticEvolver.crossover(genomes[i], donor, using: r)
                networks[i] = try! NeuralNetwork(genome: genomes[i])
            }
        }
    }

    private func donorGenomeForLineageSwap() -> Genome {
        if let bestDeadIdx = (0..<size)
            .filter({ !agents[$0].alive })
            .max(by: { agents[$0].fitness < agents[$1].fitness }) {
            return genomes[bestDeadIdx]
        }
        // Fallback: lowest-fitness alive (so we still perturb the lineage).
        let worstAliveIdx = (0..<size)
            .filter { agents[$0].alive }
            .min(by: { agents[$0].fitness < agents[$1].fitness }) ?? 0
        return genomes[worstAliveIdx]
    }

    // MARK: testing hooks
    public func killAllForTesting() {
        for i in 0..<size { agents[i].alive = false }
    }

    public func killOneForTesting() {
        for i in 0..<size {
            if agents[i].alive { agents[i].alive = false; return }
        }
    }

    public func genomesForTesting() -> [Genome] { genomes }
    public var jumpBoostUntilForTesting: Float { jumpBoostUntilSimTime }

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
