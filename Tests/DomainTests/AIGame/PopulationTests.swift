import XCTest
@testable import Domain

final class PopulationTests: XCTestCase {
    private func rng(_ values: [Float] = [0.5]) -> RandomSource {
        TestRandomSource(values + Array(repeating: Float(0.5), count: 1000))
    }

    func test_initial_generation_is_one() {
        let p = Population(size: 6, seed: 1, source: rng())
        XCTAssertEqual(p.snapshot().generation, 1)
    }

    func test_initial_alive_count_equals_size() {
        let p = Population(size: 6, seed: 1, source: rng())
        XCTAssertEqual(p.snapshot().aliveCount, 6)
    }

    func test_step_advances_camera_and_returns_snapshot() {
        let p = Population(size: 6, seed: 1, source: rng())
        let snap = p.step(dt: 0.1, audio: .silence)
        XCTAssertGreaterThan(snap.cameraX, 0)
        XCTAssertEqual(snap.agents.count, 6)
    }

    func test_evolves_when_all_dead() {
        let p = Population(size: 6, seed: 1, source: rng())
        p.killAllForTesting()
        _ = p.step(dt: 1.0/60.0, audio: .silence)
        XCTAssertEqual(p.snapshot().generation, 2)
        XCTAssertEqual(p.snapshot().aliveCount, 6)
    }

    func test_randomize_resets_to_generation_one_with_fresh_genomes() {
        let p = Population(size: 6, seed: 1, source: rng())
        for _ in 0..<3 {
            p.killAllForTesting()
            _ = p.step(dt: 1.0/60.0, audio: .silence)
        }
        XCTAssertGreaterThan(p.snapshot().generation, 1)
        p.randomize()
        XCTAssertEqual(p.snapshot().generation, 1)
        XCTAssertEqual(p.snapshot().aliveCount, 6)
    }
}
