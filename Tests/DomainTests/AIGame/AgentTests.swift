import XCTest
@testable import Domain

final class AgentTests: XCTestCase {
    private func zeroNN() throws -> NeuralNetwork {
        try NeuralNetwork(genome: Genome(weights: Array(repeating: 0,
            count: Genome.expectedLength)))
    }
    private func freshWorld() -> World {
        World(seed: 7, source: TestRandomSource([0.5]))
    }

    func test_agent_falls_when_above_ground() throws {
        let world = freshWorld()
        var s = AgentState.spawn(colorSeed: 0)
        s.posY = 0.5
        let nn = try zeroNN()
        s = Agent.step(state: s, world: world, nn: nn, dt: 0.1, jumpHeld: &dummyHeld)
        XCTAssertLessThan(s.posY, 0.5)   // gravity applied
    }

    private var dummyHeld = false

    func test_agent_does_not_double_jump() throws {
        let world = freshWorld()
        var s = AgentState.spawn(colorSeed: 0)
        s.posY = world.groundY(atWorldX: 0)   // grounded
        // NN that always outputs jump=1 — use a high b2 for output 0:
        var w = [Float](repeating: 0, count: Genome.expectedLength)
        w[Genome.expectedLength - 2] = 10   // b2[0] (jump bias) → output ≈ 1
        let nn = try NeuralNetwork(genome: Genome(weights: w))
        var held = false
        s = Agent.step(state: s, world: world, nn: nn, dt: 1.0/60.0, jumpHeld: &held)
        XCTAssertGreaterThan(s.velY, 0, "first frame jumps")
        // second frame, still above ground & jump still held → no new impulse
        let velAfterFirst = s.velY
        s = Agent.step(state: s, world: world, nn: nn, dt: 1.0/60.0, jumpHeld: &held)
        XCTAssertLessThan(s.velY, velAfterFirst, "only gravity, no second impulse")
    }

    func test_agent_dies_on_spike_collision() throws {
        let world = freshWorld()
        let g = world.groundY(atWorldX: 0)
        world.obstacles.append(Obstacle(xStart: -0.1, width: 0.2, height: 0.3, kind: .spike))
        var s = AgentState.spawn(colorSeed: 0)
        s.posY = g    // grounded → inside spike vertical extent
        let nn = try zeroNN()
        s = Agent.step(state: s, world: world, nn: nn, dt: 1.0/60.0, jumpHeld: &dummyHeld)
        XCTAssertFalse(s.alive)
    }

    func test_fitness_grows_with_distance() throws {
        let world = freshWorld()
        var s = AgentState.spawn(colorSeed: 0)
        let nn = try zeroNN()
        let f0 = s.fitness
        s = Agent.step(state: s, world: world, nn: nn, dt: 0.5,
                       jumpHeld: &dummyHeld, audio: .silence)
        XCTAssertGreaterThan(s.fitness, f0)
    }
}
