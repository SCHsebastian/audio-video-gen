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
}
