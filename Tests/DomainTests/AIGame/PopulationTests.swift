import XCTest
@testable import Domain

final class PopulationTests: XCTestCase {
    private func rng(_ values: [Float] = [0.5]) -> RandomSource {
        TestRandomSource(values + Array(repeating: Float(0.5), count: 1000))
    }

    /// Varied deterministic stream; needed when a test must distinguish
    /// genomes (otherwise `Genome.random` collapses to all-zeros under the
    /// constant-0.5 default and mutation/crossover become no-ops).
    private func variedRng() -> RandomSource {
        let pattern: [Float] = [0.1, 0.7, 0.3, 0.9, 0.2, 0.8, 0.4, 0.6, 0.05, 0.95]
        var stream: [Float] = []
        stream.reserveCapacity(2000)
        for i in 0..<2000 { stream.append(pattern[i % pattern.count]) }
        return TestRandomSource(stream)
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

    func test_snapshotProgress_carries_generation_and_genome_length() {
        let p = Population(size: 6, seed: 1, source: rng())
        let snap = p.snapshotProgress(label: "x")
        XCTAssertEqual(snap.generation, 1)
        XCTAssertEqual(snap.genomes.count, 6)
        XCTAssertEqual(snap.genomeLength, Genome.expectedLength)
        XCTAssertEqual(snap.label, "x")
    }

    func test_snapshotProgress_round_trip_via_restoring_init() {
        let p = Population(size: 6, seed: 1, source: rng())
        // Force a couple of evolution rounds so generation > 1.
        for _ in 0..<3 {
            p.killAllForTesting()
            _ = p.step(dt: 1.0/60.0, audio: .silence)
        }
        let snap = p.snapshotProgress(label: "trained")
        let restored = Population(restoring: snap, source: rng())
        let s = restored.snapshot()
        XCTAssertEqual(s.generation, snap.generation)
        XCTAssertEqual(s.aliveCount, 6)
    }

    func test_onGenerationDidIncrement_fires_after_evolution() {
        let p = Population(size: 6, seed: 1, source: rng())
        var gens: [Int] = []
        p.onGenerationDidIncrement = { gens.append($0) }
        p.killAllForTesting()
        _ = p.step(dt: 1.0/60.0, audio: .silence)
        XCTAssertEqual(gens, [2])
    }

    func test_apply_catastrophicMutation_changes_all_alive_genomes() {
        let p = Population(size: 6, seed: 1, source: variedRng())
        let before = p.genomesForTesting()
        p.applyEvent(.catastrophicMutation, source: variedRng())
        XCTAssertNotEqual(p.genomesForTesting(), before)
    }

    func test_apply_cull_kills_half_of_alive() {
        let p = Population(size: 6, seed: 1, source: rng())
        XCTAssertEqual(p.snapshot().aliveCount, 6)
        p.applyEvent(.cull, source: rng())
        XCTAssertEqual(p.snapshot().aliveCount, 3)
    }

    func test_apply_jumpBoost_sets_window() {
        let p = Population(size: 6, seed: 1, source: rng())
        p.applyEvent(.jumpBoost, source: rng())
        XCTAssertGreaterThan(p.jumpBoostUntilForTesting, 0)
    }

    func test_apply_earthquake_clears_obstacles_and_reseeds_terrain() {
        let p = Population(size: 6, seed: 1, source: rng())
        // Force an obstacle into the world.
        let beat = AudioDrive(bass: 0, mid: 0.9, treble: 0, flux: 0,
                              beatPulse: 1, beatTriggered: true, bpm: 120)
        _ = p.step(dt: 1.0/60.0, audio: beat)
        XCTAssertGreaterThan(p.snapshot().obstacles.count, 0)
        let beforeTerrain = p.snapshot().terrainSamples.map(\.y)
        p.applyEvent(.earthquake, source: rng())
        XCTAssertEqual(p.snapshot().obstacles.count, 0)
        XCTAssertNotEqual(p.snapshot().terrainSamples.map(\.y), beforeTerrain)
    }

    func test_apply_bonusObstacleWave_appends_three() {
        let p = Population(size: 6, seed: 1, source: rng())
        p.applyEvent(.bonusObstacleWave, source: rng())
        XCTAssertEqual(p.snapshot().obstacles.count, 3)
    }

    func test_apply_lineageSwap_changes_alive_genomes_when_donor_exists() {
        let p = Population(size: 6, seed: 1, source: variedRng())
        // Kill one to make a donor.
        p.killOneForTesting()
        let before = p.genomesForTesting()
        p.applyEvent(.lineageSwap, source: variedRng())
        XCTAssertNotEqual(p.genomesForTesting(), before)
    }
}
