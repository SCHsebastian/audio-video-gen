import XCTest
@testable import Domain

final class AIGameValueObjectsTests: XCTestCase {
    func test_obstacle_xRange_is_xStart_to_xStart_plus_width() {
        let o = Obstacle(xStart: 1.0, width: 0.5, height: 0.3, kind: .spike)
        XCTAssertEqual(o.xEnd, 1.5, accuracy: 1e-6)
    }
    func test_agent_state_starts_alive_at_origin() {
        let a = AgentState.spawn(colorSeed: 0.5)
        XCTAssertTrue(a.alive)
        XCTAssertEqual(a.fitness, 0)
    }
    func test_snapshot_carries_generation_and_alive_count() {
        let snap = PopulationSnapshot(
            agents: [.spawn(colorSeed: 0)], obstacles: [],
            terrainSamples: [], cameraX: 0,
            generation: 3, bestFitness: 17, aliveCount: 1
        )
        XCTAssertEqual(snap.generation, 3)
        XCTAssertEqual(snap.aliveCount, 1)
        XCTAssertEqual(snap.bestFitness, 17)
    }
}
