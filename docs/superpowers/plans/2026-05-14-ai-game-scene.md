# AI Game Scene Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a 12th visualizer scene "AI Game" — a side-scrolling runner where 6 agents driven by ≤10-neuron feed-forward NNs evolve in real time inside a music-shaped procedural world.

**Architecture:** Pure-Swift Domain bounded context (`Sources/Domain/AIGame/`) holds all simulation + neural-network + genetic-algorithm logic, fully unit-tested without Apple frameworks. A thin Metal scene (`AudioVisualizer/Infrastructure/Metal/Scenes/AIGameScene.swift`) drives the sim each frame and renders its public snapshot via 3 draw calls (terrain, obstacles, agents). Wiring follows the pattern of the existing 11 scenes: `SceneKind` case, `L10nKey` case, xcstrings entries, builder closure in `MetalVisualizationRenderer.make()` and `.makeSecondary()`, and a switch arm in `randomizeCurrent()`.

**Tech Stack:** Swift 5.10, Foundation only in Domain. Metal + MetalKit in the scene + shader. SwiftPM for Domain tests, Xcode app target for the scene + smoke test. Targets macOS 14.2+.

**Spec:** [`docs/superpowers/specs/2026-05-14-ai-game-scene-design.md`](../specs/2026-05-14-ai-game-scene-design.md)

---

## File Structure

```
Sources/Domain/AIGame/
  Errors/
    AIGameError.swift                # invalidGenomeLength
  Ports/
    RandomSource.swift               # Sendable seedable PRNG abstraction
  ValueObjects/
    AudioDrive.swift                 # bass/mid/treble/flux/beatPulse/beatTriggered/bpm
    AgentState.swift                 # pos, vel, alive, fitness, colorSeed
    ObstacleKind.swift               # spike / ceiling / pit
    Obstacle.swift                   # x, width, height, kind
    TerrainSample.swift              # x, y
    Genome.swift                     # [Float] flat weights + biases (length 44)
    PopulationSnapshot.swift         # render-facing immutable snapshot
  Entities/
    NeuralNetwork.swift              # forward(inputs) -> outputs
    GeneticEvolver.swift             # crossover + mutate (pure functions)
    World.swift                      # terrain ring + obstacles + scroll
    Agent.swift                      # physics + collision + fitness
    Population.swift                 # 6 agents + generation; step(dt:audio:)
Tests/DomainTests/AIGame/
  GenomeTests.swift
  NeuralNetworkTests.swift
  GeneticEvolverTests.swift
  WorldTests.swift
  AgentTests.swift
  PopulationTests.swift
  TestRandomSource.swift             # deterministic injectable PRNG
Sources/Domain/Visualization/ValueObjects/SceneKind.swift     # add .aigame
Sources/Domain/Localization/ValueObjects/L10nKey.swift        # add sceneAIGame
Tests/DomainTests/Visualization/SceneKindTests.swift          # add .aigame to assert
AudioVisualizer/Resources/Localizable.xcstrings               # add toolbar.scene.aigame
AudioVisualizer/Infrastructure/Metal/Shaders/AIGame.metal     # 3 vertex/fragment pairs
AudioVisualizer/Infrastructure/Metal/Scenes/AIGameScene.swift # VisualizerScene impl
AudioVisualizer/Infrastructure/Metal/MetalVisualizationRenderer.swift
                                                              # builders + switch arms
AudioVisualizer/Tests/Smoke/AIGameSceneSmokeTests.swift       # builds + 1 frame
```

Each task ends with a green test + a commit. Tasks are ordered so each one unblocks the next.

---

## Phase 1 — Domain: Errors, Ports, primitive value objects

### Task 1.1: AIGameError + RandomSource port

**Files:**
- Create: `Sources/Domain/AIGame/Errors/AIGameError.swift`
- Create: `Sources/Domain/AIGame/Ports/RandomSource.swift`
- Create: `Tests/DomainTests/AIGame/TestRandomSource.swift`

- [ ] **Step 1: Write the error type**

```swift
// Sources/Domain/AIGame/Errors/AIGameError.swift
import Foundation

public enum AIGameError: Error, Equatable {
    case invalidGenomeLength(expected: Int, got: Int)
}
```

- [ ] **Step 2: Write the RandomSource port**

```swift
// Sources/Domain/AIGame/Ports/RandomSource.swift
import Foundation

/// Pluggable PRNG so tests can inject a deterministic stream and
/// `Population` / `World` stay pure-Swift testable.
public protocol RandomSource: AnyObject {
    /// Uniform Float in [0, 1).
    func nextUnit() -> Float
    /// Uniform Float in [-1, 1).
    func nextSigned() -> Float
    /// Standard-normal Float (Box–Muller).
    func nextGaussian() -> Float
}

/// Production default. Backed by `SystemRandomNumberGenerator`.
public final class SystemRandomSource: RandomSource {
    private var rng = SystemRandomNumberGenerator()
    public init() {}
    public func nextUnit() -> Float { Float.random(in: 0..<1, using: &rng) }
    public func nextSigned() -> Float { Float.random(in: -1..<1, using: &rng) }
    public func nextGaussian() -> Float {
        let u1 = max(Float.leastNonzeroMagnitude, nextUnit())
        let u2 = nextUnit()
        return sqrtf(-2 * logf(u1)) * cosf(2 * .pi * u2)
    }
}
```

- [ ] **Step 3: Write a deterministic test PRNG**

```swift
// Tests/DomainTests/AIGame/TestRandomSource.swift
import XCTest
@testable import Domain

final class TestRandomSource: RandomSource {
    private var values: [Float]
    private var index = 0
    init(_ values: [Float]) { self.values = values }
    func nextUnit() -> Float {
        defer { index = (index + 1) % values.count }
        return values[index]
    }
    func nextSigned() -> Float { nextUnit() * 2 - 1 }
    func nextGaussian() -> Float { nextSigned() }   // ±1 stand-in
}

final class TestRandomSourceTests: XCTestCase {
    func test_cycles_through_provided_values() {
        let r = TestRandomSource([0.1, 0.2, 0.3])
        XCTAssertEqual(r.nextUnit(), 0.1)
        XCTAssertEqual(r.nextUnit(), 0.2)
        XCTAssertEqual(r.nextUnit(), 0.3)
        XCTAssertEqual(r.nextUnit(), 0.1) // wraps
    }
}
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter DomainTests.TestRandomSourceTests`
Expected: PASS (1 test)

- [ ] **Step 5: Commit**

```bash
git add Sources/Domain/AIGame Tests/DomainTests/AIGame
git commit -m "feat(ai-game): AIGameError + RandomSource port + deterministic test PRNG"
```

---

### Task 1.2: AudioDrive value object

**Files:**
- Create: `Sources/Domain/AIGame/ValueObjects/AudioDrive.swift`
- Create: `Tests/DomainTests/AIGame/AudioDriveTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/DomainTests/AIGame/AudioDriveTests.swift
import XCTest
@testable import Domain

final class AudioDriveTests: XCTestCase {
    func test_silence_is_all_zero() {
        let s = AudioDrive.silence
        XCTAssertEqual(s.bass, 0); XCTAssertEqual(s.mid, 0)
        XCTAssertEqual(s.treble, 0); XCTAssertEqual(s.flux, 0)
        XCTAssertEqual(s.beatPulse, 0); XCTAssertFalse(s.beatTriggered)
        XCTAssertEqual(s.bpm, 0)
    }
    func test_is_value_type_equatable() {
        let a = AudioDrive(bass: 0.5, mid: 0.1, treble: 0.2, flux: 0.3,
                           beatPulse: 0.7, beatTriggered: true, bpm: 120)
        let b = a
        XCTAssertEqual(a, b)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter DomainTests.AudioDriveTests`
Expected: FAIL (`AudioDrive` undefined)

- [ ] **Step 3: Write the implementation**

```swift
// Sources/Domain/AIGame/ValueObjects/AudioDrive.swift
import Foundation

public struct AudioDrive: Equatable, Sendable {
    public let bass: Float
    public let mid: Float
    public let treble: Float
    public let flux: Float
    public let beatPulse: Float
    public let beatTriggered: Bool
    public let bpm: Float

    public init(bass: Float, mid: Float, treble: Float, flux: Float,
                beatPulse: Float, beatTriggered: Bool, bpm: Float) {
        self.bass = bass; self.mid = mid; self.treble = treble; self.flux = flux
        self.beatPulse = beatPulse; self.beatTriggered = beatTriggered; self.bpm = bpm
    }

    public static let silence = AudioDrive(
        bass: 0, mid: 0, treble: 0, flux: 0,
        beatPulse: 0, beatTriggered: false, bpm: 0
    )
}
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter DomainTests.AudioDriveTests`
Expected: PASS (2 tests)

- [ ] **Step 5: Commit**

```bash
git add Sources/Domain/AIGame/ValueObjects/AudioDrive.swift Tests/DomainTests/AIGame/AudioDriveTests.swift
git commit -m "feat(ai-game): AudioDrive value object"
```

---

### Task 1.3: Genome — length, random, crossover, mutate

**Files:**
- Create: `Sources/Domain/AIGame/ValueObjects/Genome.swift`
- Create: `Sources/Domain/AIGame/Entities/GeneticEvolver.swift`
- Create: `Tests/DomainTests/AIGame/GenomeTests.swift`
- Create: `Tests/DomainTests/AIGame/GeneticEvolverTests.swift`

- [ ] **Step 1: Write failing tests for Genome length + factory**

```swift
// Tests/DomainTests/AIGame/GenomeTests.swift
import XCTest
@testable import Domain

final class GenomeTests: XCTestCase {
    func test_expected_length_is_44() {
        // 6×4 W1 + 6 b1 + 2×6 W2 + 2 b2 = 44
        XCTAssertEqual(Genome.expectedLength, 44)
    }

    func test_random_genome_has_expected_length() {
        let r = TestRandomSource(Array(repeating: 0.5, count: 8))
        let g = Genome.random(using: r)
        XCTAssertEqual(g.weights.count, Genome.expectedLength)
    }

    func test_random_genome_values_are_in_minus_one_to_one() {
        let r = TestRandomSource(Array(repeating: 0.0, count: 4)) // → -1
        let g = Genome.random(using: r)
        XCTAssertTrue(g.weights.allSatisfy { $0 >= -1 && $0 < 1 })
    }
}
```

- [ ] **Step 2: Write failing tests for GeneticEvolver**

```swift
// Tests/DomainTests/AIGame/GeneticEvolverTests.swift
import XCTest
@testable import Domain

final class GeneticEvolverTests: XCTestCase {
    private func g(_ values: [Float]) -> Genome { Genome(weights: values) }

    func test_crossover_produces_correct_length() {
        let a = g(Array(repeating: 0.5, count: Genome.expectedLength))
        let b = g(Array(repeating: -0.5, count: Genome.expectedLength))
        let r = TestRandomSource([0.1, 0.9, 0.1, 0.9])
        let child = GeneticEvolver.crossover(a, b, using: r)
        XCTAssertEqual(child.weights.count, Genome.expectedLength)
    }

    func test_crossover_picks_from_a_when_random_lt_half() {
        let a = g(Array(repeating: 1.0, count: Genome.expectedLength))
        let b = g(Array(repeating: -1.0, count: Genome.expectedLength))
        let r = TestRandomSource([0.0])     // always < 0.5 → always pick a
        let child = GeneticEvolver.crossover(a, b, using: r)
        XCTAssertEqual(child.weights.allSatisfy { $0 == 1.0 }, true)
    }

    func test_mutation_with_zero_rate_is_identity() {
        let original = g(Array(repeating: 0.3, count: Genome.expectedLength))
        let r = TestRandomSource([1.0])     // always >= rate → never mutate
        let mutated = GeneticEvolver.mutate(original, rate: 0.0, sigma: 0.25, using: r)
        XCTAssertEqual(mutated.weights, original.weights)
    }

    func test_mutation_clamps_to_bounds() {
        let original = g(Array(repeating: 1.99, count: Genome.expectedLength))
        // rate roll = 0 (mutate), gaussian = 1, sigma = 0.25 → +0.25 → clamp to 2.0
        let r = TestRandomSource([0.0])
        let mutated = GeneticEvolver.mutate(original, rate: 1.0, sigma: 0.25, using: r)
        XCTAssertTrue(mutated.weights.allSatisfy { $0 <= 2.0 && $0 >= -2.0 })
    }
}
```

- [ ] **Step 3: Run tests to verify failure**

Run: `swift test --filter DomainTests.GenomeTests && swift test --filter DomainTests.GeneticEvolverTests`
Expected: FAIL (`Genome`, `GeneticEvolver` undefined)

- [ ] **Step 4: Implement Genome**

```swift
// Sources/Domain/AIGame/ValueObjects/Genome.swift
import Foundation

public struct Genome: Equatable, Sendable {
    public static let inputCount  = 4
    public static let hiddenCount = 6
    public static let outputCount = 2
    public static let neuronBudget = 10
    public static let expectedLength =
        hiddenCount * inputCount      // W1
      + hiddenCount                   // b1
      + outputCount * hiddenCount     // W2
      + outputCount                   // b2

    public let weights: [Float]

    public init(weights: [Float]) { self.weights = weights }

    public static func random(using r: RandomSource) -> Genome {
        var w = [Float](); w.reserveCapacity(expectedLength)
        for _ in 0..<expectedLength { w.append(r.nextSigned()) }
        return Genome(weights: w)
    }
}
```

- [ ] **Step 5: Implement GeneticEvolver**

```swift
// Sources/Domain/AIGame/Entities/GeneticEvolver.swift
import Foundation

public enum GeneticEvolver {
    /// Per-gene 50/50 uniform crossover.
    public static func crossover(_ a: Genome, _ b: Genome, using r: RandomSource) -> Genome {
        precondition(a.weights.count == b.weights.count)
        var w = [Float](); w.reserveCapacity(a.weights.count)
        for i in 0..<a.weights.count {
            w.append(r.nextUnit() < 0.5 ? a.weights[i] : b.weights[i])
        }
        return Genome(weights: w)
    }

    /// Per-gene mutation: with probability `rate`, add N(0, sigma); clamp to ±2.
    public static func mutate(_ g: Genome, rate: Float, sigma: Float,
                              using r: RandomSource) -> Genome {
        var w = g.weights
        for i in 0..<w.count {
            if r.nextUnit() < rate {
                let delta = r.nextGaussian() * sigma
                w[i] = max(-2, min(2, w[i] + delta))
            }
        }
        return Genome(weights: w)
    }
}
```

- [ ] **Step 6: Run tests**

Run: `swift test --filter DomainTests.GenomeTests && swift test --filter DomainTests.GeneticEvolverTests`
Expected: PASS (3 + 4 tests)

- [ ] **Step 7: Commit**

```bash
git add Sources/Domain/AIGame Tests/DomainTests/AIGame/GenomeTests.swift Tests/DomainTests/AIGame/GeneticEvolverTests.swift
git commit -m "feat(ai-game): Genome (44 floats) + GeneticEvolver (crossover + mutate)"
```

---

### Task 1.4: NeuralNetwork — forward pass

**Files:**
- Create: `Sources/Domain/AIGame/Entities/NeuralNetwork.swift`
- Create: `Tests/DomainTests/AIGame/NeuralNetworkTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
// Tests/DomainTests/AIGame/NeuralNetworkTests.swift
import XCTest
@testable import Domain

final class NeuralNetworkTests: XCTestCase {
    func test_neuron_budget_within_10() {
        XCTAssertLessThanOrEqual(Genome.hiddenCount + Genome.outputCount, Genome.neuronBudget)
    }

    func test_throws_on_wrong_genome_length() {
        XCTAssertThrowsError(try NeuralNetwork(genome: Genome(weights: [0, 0, 0]))) { err in
            guard case AIGameError.invalidGenomeLength(let exp, let got) = err else {
                return XCTFail("wrong error type: \(err)")
            }
            XCTAssertEqual(exp, Genome.expectedLength)
            XCTAssertEqual(got, 3)
        }
    }

    func test_forward_outputs_in_unit_range() throws {
        let zeros = Array(repeating: Float.zero, count: Genome.expectedLength)
        let nn = try NeuralNetwork(genome: Genome(weights: zeros))
        let out = nn.forward([1, -1, 0.5, -0.5])
        XCTAssertEqual(out.count, Genome.outputCount)
        for o in out {
            XCTAssertGreaterThanOrEqual(o, 0)
            XCTAssertLessThanOrEqual(o, 1)
        }
    }

    func test_forward_is_deterministic_for_fixed_genome() throws {
        let weights = (0..<Genome.expectedLength).map { Float($0) * 0.01 - 0.2 }
        let nn = try NeuralNetwork(genome: Genome(weights: weights))
        let inputs: [Float] = [0.3, -0.7, 0.1, 0.9]
        XCTAssertEqual(nn.forward(inputs), nn.forward(inputs))
    }

    func test_zero_genome_outputs_half() throws {
        // tanh(0) = 0 in hidden, then sigmoid(0) = 0.5 at output.
        let zeros = Array(repeating: Float.zero, count: Genome.expectedLength)
        let nn = try NeuralNetwork(genome: Genome(weights: zeros))
        let out = nn.forward([0.7, -0.2, 0.4, -0.1])
        for o in out { XCTAssertEqual(o, 0.5, accuracy: 1e-6) }
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter DomainTests.NeuralNetworkTests`
Expected: FAIL (`NeuralNetwork` undefined)

- [ ] **Step 3: Implement**

```swift
// Sources/Domain/AIGame/Entities/NeuralNetwork.swift
import Foundation

public final class NeuralNetwork: @unchecked Sendable {
    public let w1: [Float]   // hidden × input  (row-major: hidden-major)
    public let b1: [Float]   // hidden
    public let w2: [Float]   // output × hidden
    public let b2: [Float]   // output

    public init(genome: Genome) throws {
        guard genome.weights.count == Genome.expectedLength else {
            throw AIGameError.invalidGenomeLength(
                expected: Genome.expectedLength, got: genome.weights.count
            )
        }
        let H = Genome.hiddenCount, I = Genome.inputCount, O = Genome.outputCount
        let w = genome.weights
        var i = 0
        self.w1 = Array(w[i..<i + H * I]); i += H * I
        self.b1 = Array(w[i..<i + H]);     i += H
        self.w2 = Array(w[i..<i + O * H]); i += O * H
        self.b2 = Array(w[i..<i + O])
    }

    /// Forward pass. `inputs.count` must equal `Genome.inputCount`.
    public func forward(_ inputs: [Float]) -> [Float] {
        precondition(inputs.count == Genome.inputCount)
        let H = Genome.hiddenCount, I = Genome.inputCount, O = Genome.outputCount
        var hidden = [Float](repeating: 0, count: H)
        for j in 0..<H {
            var s: Float = b1[j]
            for k in 0..<I { s += inputs[k] * w1[j * I + k] }
            hidden[j] = tanhf(s)
        }
        var out = [Float](repeating: 0, count: O)
        for j in 0..<O {
            var s: Float = b2[j]
            for k in 0..<H { s += hidden[k] * w2[j * H + k] }
            out[j] = 1.0 / (1.0 + expf(-s))
        }
        return out
    }
}
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter DomainTests.NeuralNetworkTests`
Expected: PASS (5 tests)

- [ ] **Step 5: Commit**

```bash
git add Sources/Domain/AIGame/Entities/NeuralNetwork.swift Tests/DomainTests/AIGame/NeuralNetworkTests.swift
git commit -m "feat(ai-game): NeuralNetwork forward pass (≤10 neurons enforced)"
```

---

### Task 1.5: Obstacle / TerrainSample / AgentState / PopulationSnapshot

**Files:**
- Create: `Sources/Domain/AIGame/ValueObjects/ObstacleKind.swift`
- Create: `Sources/Domain/AIGame/ValueObjects/Obstacle.swift`
- Create: `Sources/Domain/AIGame/ValueObjects/TerrainSample.swift`
- Create: `Sources/Domain/AIGame/ValueObjects/AgentState.swift`
- Create: `Sources/Domain/AIGame/ValueObjects/PopulationSnapshot.swift`
- Create: `Tests/DomainTests/AIGame/ValueObjectsTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/DomainTests/AIGame/ValueObjectsTests.swift
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
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter DomainTests.AIGameValueObjectsTests`
Expected: FAIL (types undefined)

- [ ] **Step 3: Implement ObstacleKind**

```swift
// Sources/Domain/AIGame/ValueObjects/ObstacleKind.swift
import Foundation

public enum ObstacleKind: Equatable, Sendable {
    case spike     // jump over
    case ceiling   // duck under
    case pit       // gap in the ground
}
```

- [ ] **Step 4: Implement Obstacle**

```swift
// Sources/Domain/AIGame/ValueObjects/Obstacle.swift
import Foundation

public struct Obstacle: Equatable, Sendable {
    public let xStart: Float
    public let width: Float
    public let height: Float
    public let kind: ObstacleKind

    public init(xStart: Float, width: Float, height: Float, kind: ObstacleKind) {
        self.xStart = xStart; self.width = width; self.height = height; self.kind = kind
    }

    public var xEnd: Float { xStart + width }
}
```

- [ ] **Step 5: Implement TerrainSample**

```swift
// Sources/Domain/AIGame/ValueObjects/TerrainSample.swift
import Foundation

public struct TerrainSample: Equatable, Sendable {
    public let x: Float
    public let y: Float
    public init(x: Float, y: Float) { self.x = x; self.y = y }
}
```

- [ ] **Step 6: Implement AgentState**

```swift
// Sources/Domain/AIGame/ValueObjects/AgentState.swift
import Foundation

public struct AgentState: Equatable, Sendable {
    public var posX: Float
    public var posY: Float
    public var velY: Float
    public var alive: Bool
    public var fitness: Float
    public let colorSeed: Float    // [0, 1] — palette sample u

    public init(posX: Float, posY: Float, velY: Float,
                alive: Bool, fitness: Float, colorSeed: Float) {
        self.posX = posX; self.posY = posY; self.velY = velY
        self.alive = alive; self.fitness = fitness; self.colorSeed = colorSeed
    }

    /// Standard spawn: at world origin, on the ground, alive, zero fitness.
    public static func spawn(colorSeed: Float) -> AgentState {
        AgentState(posX: 0, posY: 0, velY: 0, alive: true, fitness: 0,
                   colorSeed: colorSeed)
    }
}
```

- [ ] **Step 7: Implement PopulationSnapshot**

```swift
// Sources/Domain/AIGame/ValueObjects/PopulationSnapshot.swift
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
```

- [ ] **Step 8: Run tests**

Run: `swift test --filter DomainTests.AIGameValueObjectsTests`
Expected: PASS (3 tests)

- [ ] **Step 9: Commit**

```bash
git add Sources/Domain/AIGame/ValueObjects Tests/DomainTests/AIGame/ValueObjectsTests.swift
git commit -m "feat(ai-game): Obstacle / TerrainSample / AgentState / PopulationSnapshot"
```

---

## Phase 2 — Domain: World + Agent + Population

### Task 2.1: World — terrain ring + scroll

**Files:**
- Create: `Sources/Domain/AIGame/Entities/World.swift`
- Create: `Tests/DomainTests/AIGame/WorldTests.swift`

- [ ] **Step 1: Write failing tests for terrain & scroll**

```swift
// Tests/DomainTests/AIGame/WorldTests.swift
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
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter DomainTests.WorldTests`
Expected: FAIL (`World` undefined)

- [ ] **Step 3: Implement World — terrain & scroll only (obstacles in Task 2.2)**

```swift
// Sources/Domain/AIGame/Entities/World.swift
import Foundation

public final class World {
    public static let terrainSampleCount = 256
    public static let terrainStrideX: Float = 0.05    // world units per sample

    public let seed: UInt64
    private let source: RandomSource

    public private(set) var cameraX: Float = 0
    public private(set) var obstacles: [Obstacle] = []
    private var samples: [Float] = []                 // y values, length = terrainSampleCount
    private var ringStart: Int = 0                    // index of leftmost sample

    /// Last spawn world-x; used to enforce min spacing in `ObstacleSpawner`.
    public internal(set) var lastSpawnX: Float = -.infinity

    public init(seed: UInt64, source: RandomSource) {
        self.seed = seed; self.source = source
        self.samples = (0..<Self.terrainSampleCount).map { i in
            Self.heightAt(worldX: Float(i) * Self.terrainStrideX, seed: seed, bass: 0)
        }
    }

    public func advance(dt: Float, audio: AudioDrive) {
        let scroll = 4.0 * (1.0 + 0.5 * audio.bass)
        cameraX += scroll * dt

        // Roll the ring forward to keep the window covering [cameraX - 0.4, +∞).
        let leftEdgeWorldX = cameraX - 0.4
        let leftIndexF = leftEdgeWorldX / Self.terrainStrideX
        let desiredLeftIndex = Int(floorf(leftIndexF))
        let currentLeftIndex = baseIndex
        let shift = desiredLeftIndex - currentLeftIndex
        if shift > 0 {
            for k in 0..<shift {
                let newWorldIndex = currentLeftIndex + Self.terrainSampleCount + k
                let x = Float(newWorldIndex) * Self.terrainStrideX
                samples[(ringStart + k) % Self.terrainSampleCount] =
                    Self.heightAt(worldX: x, seed: seed, bass: audio.bass)
            }
            ringStart = (ringStart + shift) % Self.terrainSampleCount
        }

        pruneObstacles()
        spawnIfBeat(audio)
    }

    private var baseIndex: Int { Int(floorf((cameraX - 0.4) / Self.terrainStrideX)) - 0 }
    // baseIndex is computed identically to leftIndex above for clarity in tests.

    public func terrainSamples() -> [TerrainSample] {
        var out = [TerrainSample](); out.reserveCapacity(Self.terrainSampleCount)
        for i in 0..<Self.terrainSampleCount {
            let worldIndex = baseIndex + i
            let x = Float(worldIndex) * Self.terrainStrideX
            let y = samples[(ringStart + i) % Self.terrainSampleCount]
            out.append(TerrainSample(x: x, y: y))
        }
        return out
    }

    public func groundY(atWorldX wx: Float) -> Float {
        let f = wx / Self.terrainStrideX
        let i0 = Int(floorf(f))
        let t = f - Float(i0)
        let y0 = sampleY(worldIndex: i0)
        let y1 = sampleY(worldIndex: i0 + 1)
        return y0 + (y1 - y0) * t
    }

    private func sampleY(worldIndex: Int) -> Float {
        let rel = worldIndex - baseIndex
        if rel < 0 || rel >= Self.terrainSampleCount {
            // Outside ring: synthesize on the fly (silence-bass) — only used
            // by collision queries on the very leading edge.
            return Self.heightAt(worldX: Float(worldIndex) * Self.terrainStrideX,
                                 seed: seed, bass: 0)
        }
        return samples[(ringStart + rel) % Self.terrainSampleCount]
    }

    // MARK: deterministic value-noise

    static func heightAt(worldX: Float, seed: UInt64, bass: Float) -> Float {
        let baseline: Float = -0.55
        let n1 = noise1D(worldX * 0.6, seed: seed &+ 1) * 0.18
        let n2 = noise1D(worldX * 1.7, seed: seed &+ 2) * 0.06
        let bassRoll = bass * sinf(worldX * 0.9) * 0.18
        return baseline + n1 + n2 + bassRoll
    }

    private static func noise1D(_ x: Float, seed: UInt64) -> Float {
        let i = Int(floorf(x))
        let t = x - Float(i)
        let u = t * t * (3 - 2 * t)
        let a = hashUnitSigned(i, seed: seed)
        let b = hashUnitSigned(i + 1, seed: seed)
        return a + (b - a) * u
    }

    private static func hashUnitSigned(_ i: Int, seed: UInt64) -> Float {
        var h: UInt64 = UInt64(bitPattern: Int64(i)) &+ seed
        h ^= (h >> 33); h = h &* 0xff51afd7ed558ccd
        h ^= (h >> 33); h = h &* 0xc4ceb9fe1a85ec53
        h ^= (h >> 33)
        let unit = Float(h % 1_000_000) / 1_000_000.0
        return unit * 2 - 1
    }

    // MARK: obstacles (filled in Task 2.2)

    fileprivate func pruneObstacles() {
        obstacles.removeAll { $0.xEnd < cameraX - 1.6 }
    }

    fileprivate func spawnIfBeat(_ audio: AudioDrive) {
        // Implemented in Task 2.2.
    }
}
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter DomainTests.WorldTests`
Expected: PASS (5 tests)

- [ ] **Step 5: Commit**

```bash
git add Sources/Domain/AIGame/Entities/World.swift Tests/DomainTests/AIGame/WorldTests.swift
git commit -m "feat(ai-game): World terrain ring + scroll + groundY interpolation"
```

---

### Task 2.2: World — beat-driven obstacle spawner

**Files:**
- Modify: `Sources/Domain/AIGame/Entities/World.swift`
- Modify: `Tests/DomainTests/AIGame/WorldTests.swift`

- [ ] **Step 1: Append failing tests**

Add inside `WorldTests`:

```swift
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
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter DomainTests.WorldTests`
Expected: FAIL (6 new tests fail — `obstacles` empty everywhere)

- [ ] **Step 3: Replace `spawnIfBeat(_:)` body**

In `Sources/Domain/AIGame/Entities/World.swift`, replace the empty spawner with:

```swift
    fileprivate func spawnIfBeat(_ audio: AudioDrive) {
        guard audio.beatTriggered else { return }

        let spawnP: Float = max(0, min(0.85, 0.35 + 0.4 * audio.mid))
        if source.nextUnit() >= spawnP { return }

        let bpmForSpacing = audio.bpm > 0 ? audio.bpm : 60
        let minSpacing = max(Float(0.8), 60.0 / max(bpmForSpacing, 60))
        if cameraX + 1.4 - lastSpawnX < minSpacing { return }

        let kind: ObstacleKind = {
            if audio.treble > 0.55 && audio.flux > 0.4 { return .ceiling }
            if audio.bass > 0.5 { return .pit }
            return .spike
        }()
        let height: Float = 0.18 + 0.32 * audio.flux
        let width: Float = {
            switch kind { case .spike: return 0.12; case .ceiling: return 0.40; case .pit: return 0.45 }
        }()
        let spawnX = cameraX + 1.4
        obstacles.append(Obstacle(xStart: spawnX, width: width, height: height, kind: kind))
        lastSpawnX = spawnX
    }
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter DomainTests.WorldTests`
Expected: PASS (11 total now)

- [ ] **Step 5: Commit**

```bash
git add Sources/Domain/AIGame/Entities/World.swift Tests/DomainTests/AIGame/WorldTests.swift
git commit -m "feat(ai-game): beat-driven obstacle spawner with min-spacing + kind selection"
```

---

### Task 2.3: Agent physics + collision

**Files:**
- Create: `Sources/Domain/AIGame/Entities/Agent.swift`
- Create: `Tests/DomainTests/AIGame/AgentTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
// Tests/DomainTests/AIGame/AgentTests.swift
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
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter DomainTests.AgentTests`
Expected: FAIL (`Agent` undefined)

- [ ] **Step 3: Implement Agent**

```swift
// Sources/Domain/AIGame/Entities/Agent.swift
import Foundation

public enum Agent {
    public static let gravity: Float = -3.6
    public static let jumpImpulse: Float = 1.8
    public static let groundEpsilon: Float = 0.02
    public static let agentHalfHeight: Float = 0.10

    /// Advance an agent one tick. Returns the new state. `jumpHeld` is the
    /// caller-owned latch used to enforce single-impulse jumps (caller passes
    /// the same Bool for the same agent across frames).
    public static func step(state: AgentState, world: World, nn: NeuralNetwork,
                            dt: Float, jumpHeld: inout Bool,
                            audio: AudioDrive = .silence) -> AgentState {
        var s = state
        guard s.alive else { return s }

        // 1) Build NN inputs from the next obstacle (if any).
        let next = nextObstacle(after: s.posX, in: world)
        let inputs = nnInputs(state: s, next: next, world: world)
        let out = nn.forward(inputs)
        let jumpOut = out[0]
        // out[1] is duck — we keep the NN dimensionality but the simple physics
        // model below only needs to track grounded jump impulses; duck is
        // applied at collision time as a hitbox shrink.

        // 2) Jump impulse with edge-detect.
        let groundY = world.groundY(atWorldX: s.posX)
        let onGround = (s.posY - groundY) <= groundEpsilon
        let pressed = jumpOut > 0.55
        if pressed, onGround, !jumpHeld {
            s.velY = jumpImpulse
        }
        jumpHeld = pressed

        // 3) Gravity + integrate.
        s.velY += gravity * dt
        s.posY += s.velY * dt
        s.posX += worldScrollSpeed(audio) * dt
        if s.posY < groundY {
            s.posY = groundY
            s.velY = 0
        }

        // 4) Collision against any overlapping obstacle.
        let agentTop    = s.posY + (out[1] > 0.5 ? agentHalfHeight * 0.5 : agentHalfHeight)
        let agentBottom = s.posY - agentHalfHeight * 0.4
        for o in world.obstacles where o.xStart <= s.posX && s.posX <= o.xEnd {
            switch o.kind {
            case .spike:
                if agentBottom < groundY + o.height { s.alive = false }
            case .ceiling:
                if agentTop > 1.0 - o.height { s.alive = false }
            case .pit:
                if s.posY - groundY < 0.05 { s.alive = false }
            }
            if !s.alive { break }
        }

        // 5) Fitness.
        if s.alive {
            s.fitness += worldScrollSpeed(audio) * dt + 0.05 * dt * audio.flux
        }
        return s
    }

    public static func worldScrollSpeed(_ audio: AudioDrive) -> Float {
        4.0 * (1.0 + 0.5 * audio.bass)
    }

    private static func nextObstacle(after x: Float, in world: World) -> Obstacle? {
        world.obstacles.filter { $0.xEnd > x }.min { $0.xStart < $1.xStart }
    }

    private static func nnInputs(state: AgentState, next: Obstacle?, world: World) -> [Float] {
        let groundY = world.groundY(atWorldX: state.posX)
        let dist = next.map { max(0, $0.xStart - state.posX) } ?? 1.5
        let h: Float = next.map { o in
            switch o.kind { case .pit: return -o.height; default: return o.height }
        } ?? 0
        return [
            (min(dist / 1.5, 1)) * 2 - 1,
            (min(abs(h) / 0.5, 1) * (h >= 0 ? 1 : -1)) * 2 - 1,
            max(-1, min(1, state.velY / 3.0)),
            (min(max(0, state.posY - groundY) / 0.6, 1)) * 2 - 1,
        ]
    }
}
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter DomainTests.AgentTests`
Expected: PASS (4 tests)

- [ ] **Step 5: Commit**

```bash
git add Sources/Domain/AIGame/Entities/Agent.swift Tests/DomainTests/AIGame/AgentTests.swift
git commit -m "feat(ai-game): Agent physics + collision + edge-detected single-jump"
```

---

### Task 2.4: Population — step + evolution

**Files:**
- Create: `Sources/Domain/AIGame/Entities/Population.swift`
- Create: `Tests/DomainTests/AIGame/PopulationTests.swift`

- [ ] **Step 1: Write failing tests**

```swift
// Tests/DomainTests/AIGame/PopulationTests.swift
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
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter DomainTests.PopulationTests`
Expected: FAIL (`Population` undefined)

- [ ] **Step 3: Implement Population**

```swift
// Sources/Domain/AIGame/Entities/Population.swift
import Foundation

public final class Population {
    public let size: Int
    private let source: RandomSource
    private let worldSeed: UInt64

    private var world: World
    private var genomes: [Genome]
    private var networks: [NeuralNetwork]
    private var agents: [AgentState]
    private var jumpLatches: [Bool]
    private(set) public var generation: Int = 1
    private var bestFitness: Float = 0

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
    }
}
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter DomainTests.PopulationTests`
Expected: PASS (5 tests)

- [ ] **Step 5: Run the entire Domain suite to make sure nothing regressed**

Run: `swift test`
Expected: All Domain tests pass (existing + new); under 2 s.

- [ ] **Step 6: Commit**

```bash
git add Sources/Domain/AIGame/Entities/Population.swift Tests/DomainTests/AIGame/PopulationTests.swift
git commit -m "feat(ai-game): Population.step + GA evolution + randomize()"
```

---

## Phase 3 — SceneKind + Localization

### Task 3.1: Add `SceneKind.aigame`

**Files:**
- Modify: `Sources/Domain/Visualization/ValueObjects/SceneKind.swift`
- Modify: `Tests/DomainTests/Visualization/SceneKindTests.swift`

- [ ] **Step 1: Update the failing test first**

In `Tests/DomainTests/Visualization/SceneKindTests.swift`, replace the
`test_all_scenes_present` body with the 12-scene set:

```swift
    func test_all_scenes_present() {
        XCTAssertEqual(Set(SceneKind.allCases),
                       [.bars, .scope, .alchemy, .tunnel, .lissajous, .radial, .rings,
                        .synthwave, .spectrogram, .milkdrop, .kaleidoscope, .aigame])
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter DomainTests.SceneKindTests`
Expected: FAIL (set differs)

- [ ] **Step 3: Add the case**

In `Sources/Domain/Visualization/ValueObjects/SceneKind.swift`:

```swift
public enum SceneKind: String, CaseIterable, Equatable, Hashable, Sendable {
    case bars, scope, alchemy, tunnel, lissajous, radial, rings,
         synthwave, spectrogram, milkdrop, kaleidoscope, aigame
}
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter DomainTests.SceneKindTests`
Expected: PASS (2 tests)

- [ ] **Step 5: Commit**

```bash
git add Sources/Domain/Visualization/ValueObjects/SceneKind.swift Tests/DomainTests/Visualization/SceneKindTests.swift
git commit -m "feat(ai-game): SceneKind.aigame + test"
```

---

### Task 3.2: L10nKey + Localizable.xcstrings entry

**Files:**
- Modify: `Sources/Domain/Localization/ValueObjects/L10nKey.swift`
- Modify: `AudioVisualizer/Resources/Localizable.xcstrings`

- [ ] **Step 1: Add the L10nKey case**

In `Sources/Domain/Localization/ValueObjects/L10nKey.swift`, add right after
`case sceneKaleidoscope`:

```swift
    case sceneAIGame              = "toolbar.scene.aigame"
```

- [ ] **Step 2: Add xcstrings entry (use a Python helper to keep JSON valid)**

Run from repo root:

```bash
python3 - <<'PY'
import json, pathlib
p = pathlib.Path("AudioVisualizer/Resources/Localizable.xcstrings")
d = json.loads(p.read_text())
d["strings"]["toolbar.scene.aigame"] = {
    "localizations": {
        "en": {"stringUnit": {"state": "translated", "value": "AI Game"}},
        "es": {"stringUnit": {"state": "translated", "value": "Juego IA"}},
    }
}
p.write_text(json.dumps(d, indent=2, ensure_ascii=False) + "\n")
PY
```

- [ ] **Step 3: Verify both files compile / read**

Run: `swift test --filter DomainTests.LanguageTests` (or any Domain test) to
make sure the new L10nKey doesn't break the existing localizer tests.
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add Sources/Domain/Localization/ValueObjects/L10nKey.swift AudioVisualizer/Resources/Localizable.xcstrings
git commit -m "feat(ai-game): L10nKey.sceneAIGame + en/es xcstrings entries"
```

---

## Phase 4 — Metal scene + shaders

### Task 4.1: AIGame.metal shader file

**Files:**
- Create: `AudioVisualizer/Infrastructure/Metal/Shaders/AIGame.metal`

- [ ] **Step 1: Write the shader**

```metal
#include <metal_stdlib>
using namespace metal;

// ----------------------------------------------------------------------------
// AI Game scene — terrain strip + obstacle quads + agent quads.
// All three pipelines share the same camera-shake offset uniform; obstacles
// and agents are instanced. Palette texture is sampled for color so the scene
// inherits the user's currently-active palette like every other scene.
// ----------------------------------------------------------------------------

struct AIGameSceneUniforms {
    float aspect;
    float time;
    float cameraX;
    float cameraOffsetX;
    float cameraOffsetY;
    float rms;
    float beat;
};

struct VOut {
    float4 position [[position]];
    float2 local;        // -1..1 within the primitive
    float  paletteU;     // 0..1
    float  flags;        // 0 = neutral, 1 = danger, 2 = pit
};

// ----- Terrain strip ---------------------------------------------------------
// Vertex stream: pairs (x_world, y_top) and (x_world, y_bottom=-1). We build
// the strip CPU-side as floats and pass per-vertex.

struct TerrainVertex {
    float2 worldPos;     // world coords (x, y)
};

vertex VOut aigame_terrain_vertex(uint vid [[vertex_id]],
                                  constant TerrainVertex* verts [[buffer(0)]],
                                  constant AIGameSceneUniforms& u [[buffer(1)]]) {
    float2 wp = verts[vid].worldPos;
    float2 ndc = float2((wp.x - u.cameraX), wp.y) + float2(u.cameraOffsetX, u.cameraOffsetY);
    ndc.x /= u.aspect;
    VOut o;
    o.position = float4(ndc, 0, 1);
    o.local    = float2(0, wp.y);
    o.paletteU = 0.92;
    o.flags    = 0;
    return o;
}

fragment float4 aigame_terrain_fragment(VOut in [[stage_in]],
                                        constant AIGameSceneUniforms& u [[buffer(1)]],
                                        texture2d<float> palette [[texture(0)]]) {
    constexpr sampler s(filter::linear);
    float4 c = palette.sample(s, float2(in.paletteU, 0.5));
    c.rgb *= 0.55 + 0.25 * u.rms;
    return c;
}

// ----- Obstacle instanced quads ---------------------------------------------

struct ObstacleInstance {
    float2 worldPos;     // bottom-left in world coords
    float2 size;         // width, height in world units
    float  flags;        // 0 spike, 1 ceiling, 2 pit
};

vertex VOut aigame_obstacle_vertex(uint vid [[vertex_id]],
                                   uint iid [[instance_id]],
                                   constant ObstacleInstance* insts [[buffer(0)]],
                                   constant AIGameSceneUniforms& u [[buffer(1)]]) {
    float2 quad[6] = { float2(0,0), float2(1,0), float2(0,1),
                       float2(1,0), float2(1,1), float2(0,1) };
    float2 q = quad[vid];
    ObstacleInstance ins = insts[iid];
    // Pit: draw downward (height extends below ground).
    float2 size = ins.flags == 2.0 ? float2(ins.size.x, -ins.size.y) : ins.size;
    float2 wp = ins.worldPos + float2(q.x * size.x, q.y * size.y);
    float2 ndc = float2((wp.x - u.cameraX), wp.y) + float2(u.cameraOffsetX, u.cameraOffsetY);
    ndc.x /= u.aspect;
    VOut o;
    o.position = float4(ndc, 0, 1);
    o.local    = q * 2 - 1;
    o.paletteU = 0.55;
    o.flags    = ins.flags;
    return o;
}

fragment float4 aigame_obstacle_fragment(VOut in [[stage_in]],
                                         texture2d<float> palette [[texture(0)]]) {
    constexpr sampler s(filter::linear);
    float4 c = palette.sample(s, float2(in.paletteU, 0.5));
    if (in.flags == 0.0)      c.rgb = mix(c.rgb, float3(1.0, 0.25, 0.20), 0.55);
    else if (in.flags == 1.0) c.rgb = mix(c.rgb, float3(1.0, 0.55, 0.20), 0.55);
    else                       c.rgb = float3(0.04, 0.02, 0.06);
    // Soft rounded edge.
    float r = length(in.local);
    float aa = 1.0 - smoothstep(0.92, 1.0, r);
    return float4(c.rgb, aa);
}

// ----- Agent instanced quads -------------------------------------------------

struct AgentInstance {
    float2 worldPos;     // center in world coords
    float  size;         // radius
    float  colorSeed;    // 0..1, palette u
    float  alive;        // 1 alive / 0 dead
};

vertex VOut aigame_agent_vertex(uint vid [[vertex_id]],
                                uint iid [[instance_id]],
                                constant AgentInstance* insts [[buffer(0)]],
                                constant AIGameSceneUniforms& u [[buffer(1)]]) {
    float2 quad[6] = { float2(-1,-1), float2( 1,-1), float2(-1, 1),
                       float2( 1,-1), float2( 1, 1), float2(-1, 1) };
    AgentInstance ins = insts[iid];
    float2 q = quad[vid];
    float2 wp = ins.worldPos + q * ins.size;
    float2 ndc = float2((wp.x - u.cameraX), wp.y) + float2(u.cameraOffsetX, u.cameraOffsetY);
    ndc.x /= u.aspect;
    VOut o;
    o.position = float4(ndc, 0, 1);
    o.local    = q;
    o.paletteU = ins.colorSeed;
    o.flags    = ins.alive;
    return o;
}

fragment float4 aigame_agent_fragment(VOut in [[stage_in]],
                                      texture2d<float> palette [[texture(0)]]) {
    constexpr sampler s(filter::linear);
    float r = length(in.local);
    float body = 1.0 - smoothstep(0.85, 1.0, r);
    if (body <= 0) discard_fragment();
    float4 c = palette.sample(s, float2(in.paletteU, 0.5));
    // Two eyes: small dark dots at (±0.35, 0.25).
    float2 le = in.local - float2(-0.35, 0.25);
    float2 re = in.local - float2( 0.35, 0.25);
    float eye = max(1.0 - smoothstep(0.05, 0.12, length(le)),
                    1.0 - smoothstep(0.05, 0.12, length(re)));
    c.rgb = mix(c.rgb, float3(0.05, 0.05, 0.10), eye);
    float a = body * (in.flags > 0.5 ? 0.65 : 0.18); // dim dead agents
    return float4(c.rgb * a, a);
}
```

- [ ] **Step 2: Regenerate the Xcode project so the new shader is included**

Run: `xcodegen generate`
Expected: ` ⚙️  Generated project successfully`

- [ ] **Step 3: Compile-check with the app target**

Run: `xcodebuild -project AudioVisualizer.xcodeproj -scheme AudioVisualizer -destination 'platform=macOS' build -quiet`
Expected: `** BUILD SUCCEEDED **` (the shader compiles even though the Swift
scene that references the function names doesn't exist yet — Metal functions
are linked lazily at `makeFunction(name:)` time, not at link time).

- [ ] **Step 4: Commit**

```bash
git add AudioVisualizer/Infrastructure/Metal/Shaders/AIGame.metal AudioVisualizer.xcodeproj
git commit -m "feat(ai-game): metal shaders (terrain strip + obstacles + agents)"
```

---

### Task 4.2: AIGameScene.swift

**Files:**
- Create: `AudioVisualizer/Infrastructure/Metal/Scenes/AIGameScene.swift`

- [ ] **Step 1: Write the scene**

```swift
// AudioVisualizer/Infrastructure/Metal/Scenes/AIGameScene.swift
import Metal
import simd
import Domain

/// Side-scrolling runner with 6 ≤10-neuron agents evolving in real time inside
/// a music-shaped procedural world. Holds a `Domain.Population` (pure Swift)
/// and renders its public snapshot via three instanced/strip draw calls.
final class AIGameScene: VisualizerScene {
    private static let populationSize = 6
    private static let agentRadius: Float = 0.06

    private var paletteTexture: MTLTexture!
    private var device: MTLDevice!

    private var terrainPipeline: MTLRenderPipelineState!
    private var obstaclePipeline: MTLRenderPipelineState!
    private var agentPipeline: MTLRenderPipelineState!

    private var terrainBuffer: MTLBuffer!
    private var obstacleBuffer: MTLBuffer!
    private var agentBuffer: MTLBuffer!

    private var population: Population!
    private var simTime: Float = 0
    private var beatEnv: Float = 0
    private var bass: Float = 0
    private var mid: Float = 0
    private var treble: Float = 0
    private var lastSnapshot: PopulationSnapshot!

    func build(device: MTLDevice, library: MTLLibrary, paletteTexture: MTLTexture) throws {
        self.device = device
        self.paletteTexture = paletteTexture

        terrainPipeline  = try Self.makePipeline(device: device, library: library,
                                                 vertex: "aigame_terrain_vertex",
                                                 fragment: "aigame_terrain_fragment",
                                                 name: "AIGame.terrain")
        obstaclePipeline = try Self.makePipeline(device: device, library: library,
                                                 vertex: "aigame_obstacle_vertex",
                                                 fragment: "aigame_obstacle_fragment",
                                                 name: "AIGame.obstacle")
        agentPipeline    = try Self.makePipeline(device: device, library: library,
                                                 vertex: "aigame_agent_vertex",
                                                 fragment: "aigame_agent_fragment",
                                                 name: "AIGame.agent")

        // Allocate scratch GPU buffers sized for the worst case.
        let terrainStride = MemoryLayout<SIMD2<Float>>.stride
        terrainBuffer = device.makeBuffer(length: World.terrainSampleCount * 2 * terrainStride,
                                          options: .storageModeShared)
        obstacleBuffer = device.makeBuffer(length: 32 * MemoryLayout<ObstacleInstanceUniform>.stride,
                                           options: .storageModeShared)
        agentBuffer = device.makeBuffer(length: Self.populationSize * MemoryLayout<AgentInstanceUniform>.stride,
                                        options: .storageModeShared)

        let seed = UInt64.random(in: 1...UInt64.max)
        population = Population(size: Self.populationSize, seed: seed,
                                source: SystemRandomSource())
        lastSnapshot = population.snapshot()
    }

    func update(spectrum: SpectrumFrame, waveform: WaveformBuffer, beat: BeatEvent?, dt: Float) {
        bass   = max(spectrum.bass,   bass   * 0.88)
        mid    = max(spectrum.mid,    mid    * 0.85)
        treble = max(spectrum.treble, treble * 0.80)
        let triggered = (beat != nil)
        if let b = beat { beatEnv = max(beatEnv, b.strength) }
        beatEnv *= expf(-dt / 0.150)
        simTime += dt

        let drive = AudioDrive(
            bass: bass, mid: mid, treble: treble, flux: spectrum.flux,
            beatPulse: beatEnv, beatTriggered: triggered,
            bpm: beat?.bpm ?? 0
        )
        lastSnapshot = population.step(dt: dt, audio: drive)
    }

    func randomize() {
        population.randomize()
    }

    func encode(into enc: MTLRenderCommandEncoder, uniforms: inout SceneUniforms) {
        var u = AIGameSceneUniforms(
            aspect: uniforms.aspect, time: simTime,
            cameraX: lastSnapshot.cameraX,
            cameraOffsetX: sinf(simTime * 60) * 0.012 * beatEnv,
            cameraOffsetY: cosf(simTime * 73) * 0.012 * beatEnv,
            rms: uniforms.rms, beat: beatEnv
        )

        // 1) Terrain strip — pairs (x, y_top), (x, -1.0).
        let samples = lastSnapshot.terrainSamples
        let bottom: Float = -1.0
        var terrain: [SIMD2<Float>] = []
        terrain.reserveCapacity(samples.count * 2)
        for s in samples {
            terrain.append(SIMD2(s.x, s.y))
            terrain.append(SIMD2(s.x, bottom))
        }
        // Cut the strip across pit obstacles so the ground actually disappears.
        // (Cheap version: write y_top = bottom for samples whose x lies inside any pit.)
        let pits = lastSnapshot.obstacles.filter { $0.kind == .pit }
        if !pits.isEmpty {
            for i in stride(from: 0, to: terrain.count, by: 2) {
                let x = terrain[i].x
                if pits.contains(where: { $0.xStart <= x && x <= $0.xEnd }) {
                    terrain[i].y = bottom
                }
            }
        }
        let terrainBytes = terrain.count * MemoryLayout<SIMD2<Float>>.stride
        memcpy(terrainBuffer.contents(), terrain, terrainBytes)
        enc.setRenderPipelineState(terrainPipeline)
        enc.setVertexBuffer(terrainBuffer, offset: 0, index: 0)
        enc.setVertexBytes(&u, length: MemoryLayout<AIGameSceneUniforms>.stride, index: 1)
        enc.setFragmentBytes(&u, length: MemoryLayout<AIGameSceneUniforms>.stride, index: 1)
        enc.setFragmentTexture(paletteTexture, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: terrain.count)

        // 2) Obstacles.
        var obstacles: [ObstacleInstanceUniform] = lastSnapshot.obstacles.map { o in
            let groundY = lookupGroundY(at: o.xStart, in: samples)
            let bottomY: Float = (o.kind == .ceiling) ? (1.0 - o.height) : groundY
            let flag: Float = (o.kind == .spike) ? 0 : (o.kind == .ceiling) ? 1 : 2
            return ObstacleInstanceUniform(worldPos: SIMD2(o.xStart, bottomY),
                                           size: SIMD2(o.width, o.height),
                                           flags: flag)
        }
        if !obstacles.isEmpty {
            let bytes = obstacles.count * MemoryLayout<ObstacleInstanceUniform>.stride
            memcpy(obstacleBuffer.contents(), &obstacles, bytes)
            enc.setRenderPipelineState(obstaclePipeline)
            enc.setVertexBuffer(obstacleBuffer, offset: 0, index: 0)
            enc.setVertexBytes(&u, length: MemoryLayout<AIGameSceneUniforms>.stride, index: 1)
            enc.setFragmentTexture(paletteTexture, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0,
                               vertexCount: 6, instanceCount: obstacles.count)
        }

        // 3) Agents.
        var agents: [AgentInstanceUniform] = lastSnapshot.agents.map { a in
            AgentInstanceUniform(worldPos: SIMD2(a.posX, a.posY),
                                 size: Self.agentRadius,
                                 colorSeed: a.colorSeed,
                                 alive: a.alive ? 1 : 0)
        }
        let agentBytes = agents.count * MemoryLayout<AgentInstanceUniform>.stride
        memcpy(agentBuffer.contents(), &agents, agentBytes)
        enc.setRenderPipelineState(agentPipeline)
        enc.setVertexBuffer(agentBuffer, offset: 0, index: 0)
        enc.setVertexBytes(&u, length: MemoryLayout<AIGameSceneUniforms>.stride, index: 1)
        enc.setFragmentTexture(paletteTexture, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0,
                           vertexCount: 6, instanceCount: agents.count)
    }

    // MARK: helpers
    private func lookupGroundY(at x: Float, in samples: [TerrainSample]) -> Float {
        // Linear search — at most 256 samples, called ≤ 8× per frame.
        for i in 0..<(samples.count - 1) {
            if samples[i].x <= x && x <= samples[i + 1].x {
                let t = (x - samples[i].x) / (samples[i + 1].x - samples[i].x)
                return samples[i].y + (samples[i + 1].y - samples[i].y) * t
            }
        }
        return samples.first?.y ?? -0.55
    }

    private static func makePipeline(device: MTLDevice, library: MTLLibrary,
                                     vertex: String, fragment: String,
                                     name: String) throws -> MTLRenderPipelineState {
        guard let v = library.makeFunction(name: vertex),
              let f = library.makeFunction(name: fragment) else {
            throw RenderError.shaderCompilationFailed(name: vertex)
        }
        let desc = MTLRenderPipelineDescriptor()
        desc.label = name
        desc.vertexFunction = v
        desc.fragmentFunction = f
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        desc.colorAttachments[0].isBlendingEnabled = true
        desc.colorAttachments[0].rgbBlendOperation = .add
        desc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        desc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        desc.colorAttachments[0].alphaBlendOperation = .add
        desc.colorAttachments[0].sourceAlphaBlendFactor = .one
        desc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        do { return try device.makeRenderPipelineState(descriptor: desc) }
        catch { throw RenderError.pipelineCreationFailed(name: name) }
    }
}

private struct AIGameSceneUniforms {
    var aspect: Float
    var time: Float
    var cameraX: Float
    var cameraOffsetX: Float
    var cameraOffsetY: Float
    var rms: Float
    var beat: Float
}

private struct ObstacleInstanceUniform {
    var worldPos: SIMD2<Float>
    var size: SIMD2<Float>
    var flags: Float
}

private struct AgentInstanceUniform {
    var worldPos: SIMD2<Float>
    var size: Float
    var colorSeed: Float
    var alive: Float
}
```

- [ ] **Step 2: Regenerate Xcode project**

Run: `xcodegen generate`

- [ ] **Step 3: Build**

Run: `xcodebuild -project AudioVisualizer.xcodeproj -scheme AudioVisualizer -destination 'platform=macOS' build -quiet`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add AudioVisualizer/Infrastructure/Metal/Scenes/AIGameScene.swift AudioVisualizer.xcodeproj
git commit -m "feat(ai-game): AIGameScene VisualizerScene impl drives Domain.Population"
```

---

### Task 4.3: Wire into MetalVisualizationRenderer

**Files:**
- Modify: `AudioVisualizer/Infrastructure/Metal/MetalVisualizationRenderer.swift`

- [ ] **Step 1: Register the lazy builder in `make()`**

Find the block in `make()` that registers builders (line ~111). Add right
after the `.kaleidoscope` line:

```swift
        renderer.sceneBuilders[.aigame] = { [weak renderer] in try Self.build(AIGameScene(), with: renderer, d: d, lib: lib) }
```

- [ ] **Step 2: Register the same builder in `makeSecondary(...)`**

Find the analogous block in `makeSecondary` (line ~85). Add:

```swift
        r.sceneBuilders[.aigame] = { [weak r] in try Self.build(AIGameScene(), with: r, d: d, lib: lib) }
```

- [ ] **Step 3: Add the `case` in `buildScene(...)`**

Find the switch in `buildScene` (line ~127). Add:

```swift
        case .aigame:       scene = AIGameScene()
```

- [ ] **Step 4: Add the `case` in `randomizeCurrent()`**

Find the switch in `randomizeCurrent()` (line ~231). Add a case before the
final `case .scope, .synthwave, .spectrogram:` arm:

```swift
        case .aigame:    (materialize(.aigame) as? AIGameScene)?.randomize();    return "AI Game"
```

- [ ] **Step 5: Build**

Run: `xcodebuild -project AudioVisualizer.xcodeproj -scheme AudioVisualizer -destination 'platform=macOS' build -quiet`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 6: Commit**

```bash
git add AudioVisualizer/Infrastructure/Metal/MetalVisualizationRenderer.swift
git commit -m "feat(ai-game): wire AIGameScene into renderer (primary + secondary + randomize)"
```

---

## Phase 5 — Smoke test + manual verification

### Task 5.1: Add app-target smoke test for the new scene

**Files:**
- Create: `AudioVisualizer/Tests/Smoke/AIGameSceneSmokeTests.swift`

- [ ] **Step 1: Write the smoke test**

```swift
// AudioVisualizer/Tests/Smoke/AIGameSceneSmokeTests.swift
import XCTest
@testable import AudioVisualizer
import Domain

final class AIGameSceneSmokeTests: XCTestCase {
    func test_renderer_can_build_aigame_scene_without_throwing() throws {
        let r = try MetalVisualizationRenderer.make()
        // Switching to .aigame must trigger a successful materialize on next
        // consume(). Push a single zero frame to provoke build.
        r.setScene(.aigame)
        let zero = SpectrumFrame(bands: Array(repeating: 0, count: 64),
                                 rms: 0, timestamp: .zero)
        let wav = WaveformBuffer(mono: Array(repeating: 0, count: 1024))
        r.consume(spectrum: zero, waveform: wav, beat: nil)
        // If we got here without throwing, the scene built and consumed one frame.
        XCTAssertTrue(true)
    }
}
```

- [ ] **Step 2: Regenerate the Xcode project (the test file must be picked up)**

Run: `xcodegen generate`

- [ ] **Step 3: Run the test**

Run:
```bash
xcodebuild test -project AudioVisualizer.xcodeproj -scheme AudioVisualizer -destination 'platform=macOS' \
  -only-testing:AudioVisualizerTests/AIGameSceneSmokeTests/test_renderer_can_build_aigame_scene_without_throwing
```
Expected: `Test Suite 'AIGameSceneSmokeTests' passed`.

- [ ] **Step 4: Commit**

```bash
git add AudioVisualizer/Tests/Smoke/AIGameSceneSmokeTests.swift AudioVisualizer.xcodeproj
git commit -m "test(ai-game): smoke test — scene materializes and consumes one frame"
```

---

### Task 5.2: Run the entire test suite + manual launch

- [ ] **Step 1: Run Domain + Application tests**

Run: `swift test`
Expected: All Domain + Application tests pass; <2 s.

- [ ] **Step 2: Run app-target tests**

Run: `xcodebuild test -project AudioVisualizer.xcodeproj -scheme AudioVisualizer -destination 'platform=macOS' -quiet`
Expected: All tests pass.

- [ ] **Step 3: Launch the app and switch to the AI Game scene**

Run:
```bash
xcodebuild -project AudioVisualizer.xcodeproj -scheme AudioVisualizer -destination 'platform=macOS' build -quiet \
  && open ~/Library/Developer/Xcode/DerivedData/AudioVisualizer-*/Build/Products/Debug/AudioVisualizer.app
```

In the app:
- Select the **AI Game** entry in the scene picker. Verify the toolbar label
  reads "AI Game" (en) / switch language to es and verify "Juego IA".
- Verify obstacles spawn in time with beats; agents jump (some die early,
  generation increments).
- Click the canvas (existing `randomizeCurrent` gesture). Verify the toast
  reads "AI Game" and the population resets to generation 1.

- [ ] **Step 4: Stream the render log to confirm no per-frame errors**

In another terminal:
```bash
/usr/bin/log stream --predicate 'subsystem == "dev.audiovideogen.AudioVisualizer" AND category == "render"' --info --style compact
```
Expected: a `scene materialized: aigame` line on first switch and no error
lines while the scene runs.

- [ ] **Step 5: If everything looks right, commit a brief CHANGELOG entry to README**

Update the README scene list to include "AI Game (≤10-neuron evolutionary
runner)". Keep it to one bullet — this is the only doc change.

```bash
# Edit README.md scene list, then:
git add README.md
git commit -m "docs(readme): list AI Game as 12th scene"
```

- [ ] **Step 6: Push**

Run: `git push`
Expected: branch is up to date on `origin/claude/mystifying-benz-e3a470`.

---

## Self-review checklist (already applied)

- **Spec coverage:** every locked decision in the spec maps to a task —
  AudioDrive (1.2), Genome length 44 (1.3), NN ≤ 10 neurons (1.4), terrain &
  ground (2.1), beat-driven obstacle kinds + min spacing (2.2), agent
  physics & collision per kind (2.3), evolution rules + randomize (2.4),
  SceneKind (3.1), L10n (3.2), shaders (4.1), scene impl (4.2), wiring (4.3),
  smoke (5.1).
- **Placeholder scan:** none — every step ships code or an exact command.
- **Type consistency:**
  - `Genome.expectedLength`, `Genome.hiddenCount`, `Genome.outputCount`,
    `Genome.neuronBudget` defined once in 1.3 and reused everywhere.
  - `Population.step(dt:audio:)` signature stable from 2.4 → 4.2.
  - `World.terrainSampleCount`, `World.terrainStrideX`, `World.cameraX`,
    `World.obstacles`, `World.groundY(atWorldX:)`, `World.advance(dt:audio:)`
    defined in 2.1 and used in 2.3 / 4.2.
  - `AgentState` properties (`posX`, `posY`, `velY`, `alive`, `fitness`,
    `colorSeed`) consistent across 1.5 / 2.3 / 4.2.
  - `Agent.step(state:world:nn:dt:jumpHeld:audio:)` signature is identical in
    2.3 and 2.4.
  - Shader function names (`aigame_terrain_vertex` …) match the
    `library.makeFunction(name:)` calls in 4.2.
- **No spec gaps detected.**
