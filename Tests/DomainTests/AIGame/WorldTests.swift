import XCTest
@testable import Domain

final class WorldTests: XCTestCase {
    func test_initial_camera_is_zero() {
        let w = World(seed: 1, source: TestRandomSource([0.5]))
        XCTAssertEqual(w.cameraX, 0)
    }

    func test_advance_moves_camera_at_scroll_speed() {
        let w = World(seed: 1, source: TestRandomSource([0.5]))
        let before = w.cameraX
        w.advance(dt: 0.5, audio: .silence)   // baseScroll = 4 → +2 in 0.5s
        XCTAssertEqual(w.cameraX - before, 2.0, accuracy: 1e-3)
    }

    func test_terrain_is_deterministic_for_fixed_seed() {
        let a = World(seed: 42, source: TestRandomSource([0.5]))
        let b = World(seed: 42, source: TestRandomSource([0.5]))
        a.advance(dt: 0.1, audio: .silence)
        b.advance(dt: 0.1, audio: .silence)
        XCTAssertEqual(a.terrainSamples().map { $0.y }, b.terrainSamples().map { $0.y })
    }

    func test_terrain_window_returns_constant_count() {
        let w = World(seed: 1, source: TestRandomSource([0.5]))
        XCTAssertEqual(w.terrainSamples().count, World.terrainSampleCount)
        for _ in 0..<10 { w.advance(dt: 0.1, audio: .silence) }
        XCTAssertEqual(w.terrainSamples().count, World.terrainSampleCount)
    }

    func test_groundY_at_returns_value_within_terrain_amplitude() {
        let w = World(seed: 1, source: TestRandomSource([0.5]))
        let y = w.groundY(atWorldX: 0)
        // baseline = -0.55, max amplitude ~ 0.42
        XCTAssertGreaterThan(y, -1.0)
        XCTAssertLessThan(y, 0.0)
    }

    func test_beat_with_low_mid_may_skip_spawn() {
        // spawnP = 0.35 + 0.4 * mid = 0.35; r.nextUnit() = 0.9 → skip.
        let w = World(seed: 1, source: TestRandomSource([0.9]))
        let beat = AudioDrive(bass: 0, mid: 0, treble: 0, flux: 0,
                              beatPulse: 1, beatTriggered: true, bpm: 120)
        w.advance(dt: 1.0/60.0, audio: beat)
        XCTAssertEqual(w.obstacles.count, 0)
    }

    func test_beat_with_high_mid_spawns_obstacle() {
        let w = World(seed: 1, source: TestRandomSource([0.0]))   // always spawn
        let beat = AudioDrive(bass: 0, mid: 0.9, treble: 0, flux: 0.5,
                              beatPulse: 1, beatTriggered: true, bpm: 120)
        w.advance(dt: 1.0/60.0, audio: beat)
        XCTAssertEqual(w.obstacles.count, 1)
        XCTAssertEqual(w.obstacles[0].kind, .spike)
        XCTAssertEqual(w.obstacles[0].xStart, w.cameraX + 1.4, accuracy: 1e-3)
    }

    func test_high_treble_and_flux_produces_ceiling_obstacle() {
        let w = World(seed: 1, source: TestRandomSource([0.0]))
        let beat = AudioDrive(bass: 0, mid: 0.9, treble: 0.7, flux: 0.5,
                              beatPulse: 1, beatTriggered: true, bpm: 120)
        w.advance(dt: 1.0/60.0, audio: beat)
        XCTAssertEqual(w.obstacles[0].kind, .ceiling)
    }

    func test_high_bass_produces_pit_obstacle() {
        let w = World(seed: 1, source: TestRandomSource([0.0]))
        let beat = AudioDrive(bass: 0.7, mid: 0.9, treble: 0.0, flux: 0.0,
                              beatPulse: 1, beatTriggered: true, bpm: 120)
        w.advance(dt: 1.0/60.0, audio: beat)
        XCTAssertEqual(w.obstacles[0].kind, .pit)
    }

    func test_obstacle_spawn_respects_min_spacing() {
        let w = World(seed: 1, source: TestRandomSource([0.0]))
        let beat = AudioDrive(bass: 0, mid: 0.9, treble: 0, flux: 0,
                              beatPulse: 1, beatTriggered: true, bpm: 240)
        // First beat → spawn.
        w.advance(dt: 1.0/60.0, audio: beat)
        XCTAssertEqual(w.obstacles.count, 1)
        // Immediate second beat at cameraX barely moved → suppressed by spacing.
        w.advance(dt: 1.0/60.0, audio: beat)
        XCTAssertEqual(w.obstacles.count, 1)
    }

    func test_no_spawn_when_beatTriggered_false() {
        let w = World(seed: 1, source: TestRandomSource([0.0]))
        let nb = AudioDrive(bass: 0, mid: 0.9, treble: 0, flux: 0,
                            beatPulse: 0.4, beatTriggered: false, bpm: 120)
        w.advance(dt: 1.0/60.0, audio: nb)
        XCTAssertEqual(w.obstacles.count, 0)
    }
}
