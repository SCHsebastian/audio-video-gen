# AI Game scene — design

**Date:** 2026-05-14
**Status:** Draft for review.

## Goal

Add a 12th visualizer scene called **AI Game** in which a procedurally generated
2D side-scrolling world is built from the live music, and a population of small
creatures, each driven by a *tiny* feed-forward neural network (≤10 processing
neurons), learns to survive in that world via real-time genetic evolution.

The intent is showmanship rather than benchmark ML: the player should *see* the
music shaping terrain and obstacles, and *see* the herd of agents diverging,
dying, and being replaced by mutated offspring as the song plays. The 10-neuron
constraint is the visual hook — the AI is observably tiny, and its decisions
(jump / duck) are legible frame by frame.

## Non-goals

- Convergent or "good" gameplay. We are not training to a reward target — we
  are showing evolution as visual texture. A single song will not produce an
  expert agent and that is fine.
- Player input. The user does not control any agent; this is a passive
  visualizer scene like every other. (The existing canvas-tap → randomize
  gesture re-seeds the population — see "Randomize" below.)
- Persistent learning across sessions or scene changes. Leaving and re-entering
  the scene starts fresh, matching every other scene.
- More than one game mode. Pick a single side-scrolling runner; do not ship a
  game-mode picker.
- Any new framework dependency. All AI logic stays in pure-Swift Domain.
- New audio analysis. Reuse the existing `SpectrumFrame` (with its centralised
  `bass`/`mid`/`treble`/`flux` and `BeatEvent`).
- Per-agent shaders. One instanced quad pipeline draws all agents.

## Decisions (locked from brainstorming)

| Question | Choice |
|---|---|
| Game type | Side-scrolling runner with jump + duck |
| AI architecture | Feed-forward NN, 4 inputs → 6 hidden (tanh) → 2 outputs (sigmoid) = **8 processing neurons** |
| "10 neurons" semantics | **Hidden + output**, not counting inputs. Architectural ceiling enforced in code. |
| Population size | 6 simultaneous agents, drawn semi-transparent so divergence is visible |
| Evolution trigger | When all 6 are dead → cross + mutate top 2 by fitness, reseed pool |
| Music → world | Bass shapes terrain elevation; beats spawn obstacles; mid/flux scale obstacle height; tempo gates spawn cadence |
| Music → camera/feel | Beats trigger small camera shake; palette texture sampled for sky / silhouettes |
| Randomize gesture | Hard-resets the population (random genomes) and re-seeds terrain noise |
| HUD | When diagnostics overlay is on, show `gen N · alive K/6 · best fitness F` line |
| Localization | New `L10nKey.sceneAIGame`; en `"AI Game"`, es `"Juego IA"` |
| Persistence | None |

## Architecture

This scene is the first one with non-trivial *gameplay logic* that benefits
from being unit-tested in isolation. Therefore we do something the existing
scenes do not: split the scene into a **pure-Swift Domain** simulation
(`AIGame` bounded context) and a **thin Metal adapter** that drives the sim
each frame and renders its public state.

```
                 ┌────────────────────────────────────┐
                 │   Sources/Domain/AIGame/           │   (Swift only)
                 │                                    │
    audio   ───► │  Population.step(dt:audio:)        │ ───► public state:
    (bass,       │    ├ World.advance(dt, audio)      │       agents[], obstacles[],
     mid,        │    │   ├ TerrainGenerator (noise)  │       terrainSamples[],
     flux,       │    │   └ ObstacleSpawner (beats)   │       generation, fitness
     beat)       │    └ Agent.step(dt, world, nn)     │
                 │        ├ NeuralNetwork.forward()   │
                 │        └ physics + collision       │
                 │  on death → GeneticEvolver.evolve  │
                 └────────────────────────────────────┘
                                  │
                                  ▼
        ┌─────────────────────────────────────────────┐
        │ AudioVisualizer/Infrastructure/Metal/Scenes │
        │   AIGameScene.swift  (VisualizerScene)      │
        │     update(...) → population.step(...)      │
        │     encode(...)  → 3 draws:                 │
        │       1. terrain triangle strip             │
        │       2. obstacles (instanced quads)        │
        │       3. agents   (instanced quads)         │
        │     palette texture sampled for tinting     │
        └─────────────────────────────────────────────┘
```

The architectural invariant from `CLAUDE.md` is preserved: `Sources/Domain` and
`Sources/Application` import only `Foundation`.

### Bounded context: `AIGame` (Domain)

```
Sources/Domain/AIGame/
  ValueObjects/
    AgentState.swift        // pos, vel, alive, fitness, color seed
    Obstacle.swift          // x, width, height, kind (.spike / .ceiling / .pit)
    TerrainSample.swift     // x, y                           — strip vertex
    AudioDrive.swift        // bass, mid, treble, flux, beatPulse, beatTriggered
    Genome.swift            // [Float] flat weights + biases  (length = 4·6 + 6 + 6·2 + 2)
  Entities/
    NeuralNetwork.swift     // forward(inputs) -> outputs;    init(genome:)
    World.swift             // terrain + obstacles + scroll;  advance(dt:audio:)
    Agent.swift             // physics, collision, fitness;   step(dt:world:nn:)
    Population.swift        // 6 agents + generation counter; step(dt:audio:) → snapshot
    GeneticEvolver.swift    // crossover + mutation when all dead
  Errors/
    AIGameError.swift       // .invalidGenomeLength
```

No new use case is added. Like every other scene, the renderer drives the
simulation directly from `update(spectrum:waveform:beat:dt:)`. This matches
existing patterns (Alchemy, Tunnel, Synthwave all hold mutable scene state
without a use case).

### Why ports were *not* added

`Population` is a value-and-entity collaborator, not an external resource. It
is constructed and owned by `AIGameScene`, just as `AlchemyScene` owns its
particle buffer. There is no Apple-framework adapter to abstract behind a
port, so adding one would be ceremony.

## Inputs (per frame)

Same shape every other scene receives, no new analyzer plumbing:

| Name | Type | Range | Source |
|---|---|---|---|
| `spectrum.bass`/`mid`/`treble`/`flux` | `Float` | `[0,1]` | `VDSPSpectrumAnalyzer` |
| `spectrum.rms` | `Float` | `[0,1]` | analyzer |
| `beat` | `BeatEvent?` | `strength ∈ [0,1]`, `bpm ≥ 0` | `EnergyBeatDetector` |
| `dt` | `Float` | `~1/60..1/120` s | render loop |

The Domain sim consumes a small adapter struct `AudioDrive`:

```swift
public struct AudioDrive: Equatable, Sendable {
    public let bass: Float           // 0..1, peak-held in scene (decay 0.88)
    public let mid: Float            // 0..1
    public let treble: Float         // 0..1
    public let flux: Float           // 0..1
    public let beatPulse: Float      // 0..1, time-decayed beat envelope
    public let beatTriggered: Bool   // true on the frame a beat arrives
    public let bpm: Float            // 0 if unknown; clamps to [60, 200] in spawner
}
```

`AIGameScene` does the per-frame envelope smoothing (same constants as
Alchemy) and passes a fresh `AudioDrive` into `Population.step`. Domain has no
notion of "host time" or `BeatEvent` — it sees only floats.

## Algorithm

### 1. World

Coordinate system: world-x runs left to right indefinitely (we keep a moving
window). Camera-x advances at `worldScrollSpeed = 4.0 * (1 + 0.5*bass)` units
per second. The renderer subtracts camera-x so on-screen coordinates are in
[-1, 1] NDC.

#### 1.1 Terrain

A 1D height field sampled at fixed world-x stride `dx = 0.05`. We keep a
ring buffer of `T = 256` samples (covers ~12.8 world units, more than the
visible window of ~3.2 units after aspect correction).

```
height(x) = baseline
          + noise1D(x * 0.6) * 0.18
          + noise1D(x * 1.7) * 0.06
          + bassEnvelope * sin(x * 0.9) * 0.18
```

`baseline = -0.55` (NDC). Bass thus rolls visible hills slowly.
`noise1D` is a deterministic value-noise function seeded from a `UInt64` held
by `World`. Re-seeding is what `randomize()` mutates.

#### 1.2 Obstacles

`ObstacleSpawner` watches `audio.beatTriggered`. Each beat is a *candidate*
spawn:

- Probability `spawnP = 0.35 + 0.4 * audio.mid` (clamped to `[0, 0.85]`).
- Roll once; on success, spawn at `spawnX = camera.x + 1.4` (just past the
  right edge of the visible area).
- Kind chosen weighted by treble & flux:
  - `treble > 0.55 && flux > 0.4` → `.ceiling` (forces a duck)
  - else if `bass > 0.5`           → `.pit`     (forces a jump over a gap)
  - else                            → `.spike`   (single jump-over)
- Height/width: `height = 0.18 + 0.32 * audio.flux` (NDC units), width fixed
  per kind (spike: 0.12, ceiling: 0.40, pit: 0.45).
- Minimum spacing: `minSpacing = max(0.8, 60.0 / max(bpm, 60))` world units.
  The spawner suppresses any candidate that would land within `minSpacing` of
  the previous obstacle; this keeps high-tempo songs from carpet-bombing the
  field.

Obstacles older than `cameraX - 1.6` are pruned each frame.

### 2. Agent physics

Per-agent state:

```
pos     ∈ R²       (world coordinates)
vel     ∈ R²       (units / sec)
alive   : Bool
fitness : Float    (= worldDistanceSurvived + 0.05*timeAlive*audio.flux)
```

Constants:

```
gravity         = -3.6   units / s²
jumpImpulse     = +1.8   units / s   (only when on ground)
duckHeightMul   = 0.5    (effective hitbox y-extent while duck output > 0.5)
groundY(x)      = terrain height interpolated at agent x
groundEpsilon   = 0.02
```

Each frame:

1. Compute `nnInputs` (see §3).
2. `(jumpOut, duckOut) = nn.forward(nnInputs)`; both `∈ [0, 1]`.
3. If `jumpOut > 0.55` and `pos.y - groundY ≤ groundEpsilon`: set `vel.y =
   jumpImpulse`. (Edge-detect: do not double-jump while output stays high.)
4. `vel.y += gravity * dt`.
5. `pos += vel * dt`. Agent x advances at `worldScrollSpeed` (it is locked to
   the camera's scroll — this is a runner, not a free mover).
6. If `pos.y < groundY`: snap to ground, `vel.y = 0`.
7. Collision check against obstacles whose `[xStart, xEnd]` overlaps agent x:
   - `.spike`: dies if agent y < `obstacle.height + groundY`.
   - `.ceiling`: dies if effective top of agent (`pos.y + 0.10 * (duckOut < 0.5 ? 1 : duckHeightMul)`) > `1.0 - obstacle.height`.
   - `.pit`: dies if agent x is inside the pit and `pos.y - groundY < 0.05`
     (i.e. on or near the (missing) ground at that x).
8. Update `fitness` if alive.

### 3. Neural network

A flat feed-forward net, **size enforced as a `static let` constant**:

```swift
public enum NN {
    static let inputCount  = 4
    static let hiddenCount = 6   // ≤ 10
    static let outputCount = 2
    static let processingCount = hiddenCount + outputCount  // == 8
    static let neuronBudget    = 10
    // Compile-time sanity:
    // assert via test that processingCount <= neuronBudget
}
```

Inputs (all in `[-1, 1]` after normalization):

| Index | Source | Normalization |
|---|---|---|
| 0 | distance to next obstacle (world units) | `clamp(d / 1.5, 0, 1) * 2 - 1` |
| 1 | next obstacle "danger height" | `clamp(h / 0.5, 0, 1) * 2 - 1`, sign flipped if `.pit` |
| 2 | agent vertical velocity | `clamp(vel.y / 3.0, -1, 1)` |
| 3 | agent altitude above ground | `clamp(alt / 0.6, 0, 1) * 2 - 1` |

Forward pass:

```
hidden_j = tanh( Σᵢ inputᵢ · W1[j,i]  +  b1[j] )      j ∈ [0, 6)
output_k = σ   ( Σⱼ hidden_j · W2[k,j] +  b2[k] )     k ∈ [0, 2)
```

Genome layout (flat `[Float]`):

```
[ W1 (6×4 = 24) | b1 (6) | W2 (2×6 = 12) | b2 (2) ]   length = 44
```

`NeuralNetwork.init(genome:)` throws `AIGameError.invalidGenomeLength` if
`genome.count != 44`.

### 4. Genetic evolution

When `population.aliveCount == 0`:

1. Sort the dead agents by `fitness` descending.
2. Keep the top 2 ("elites").
3. Refill 6 slots:
   - Slot 0: elite #1 (unchanged) — preserves best-so-far.
   - Slot 1: elite #2 (unchanged).
   - Slots 2–5: child of `crossover(eliteA, eliteB)` then `mutate(rate, sigma)`.
4. `generation += 1`. Reset agent positions, set `alive = true`, reset world
   obstacles (terrain noise persists so the visual feel is continuous).

Cross-over: per-gene uniform crossover with 50/50 inheritance.
Mutation: per-gene chance `rate = 0.10` to add `N(0, sigma=0.25)` Gaussian
noise, then clamp to `[-2, 2]`.

The first generation has fully random genomes (`Float.random(in: -1...1)`
seeded from a `SystemRandomNumberGenerator`, captured via a Domain
`RandomSource` protocol so tests can inject a deterministic stream).

### 5. Rendering (Metal)

Three draw calls per frame, all fed from `Population.snapshot()`:

```swift
public struct PopulationSnapshot: Sendable {
    public let agents: [AgentRenderInfo]      // up to 6
    public let obstacles: [ObstacleRenderInfo]
    public let terrainSamples: [SIMD2<Float>] // already in world coords
    public let cameraX: Float
    public let generation: Int
    public let bestFitness: Float
}
```

1. **Terrain**: triangle strip from terrain samples extruded down to the
   bottom of the screen. Color: paletteTexture sampled at u=0.92 (deep end of
   palette) blended with rms for a subtle pulse.
2. **Obstacles**: instanced rounded quads, color from paletteTexture u=0.55,
   tinted red on `.spike`/`.ceiling`, dark on `.pit`.
3. **Agents**: instanced quads (rounded blob with two eye dots in the
   fragment shader). Color: paletteTexture sampled at `agent.colorSeed`
   (different per genome lineage so children inherit parent hue + small
   jitter — visualizes phylogeny). Alpha 0.65 so the herd reads as a smear.
4. **Beat camera shake**: scene uniform `cameraOffset = SIMD2(sin(time*60),
   cos(time*73)) * 0.012 * beatEnv`. Applied in vertex shaders.

All vertex/fragment/uniform structs follow the same shape as Alchemy
(`AUniforms`-style POD, set via `setVertexBytes` / `setFragmentBytes`).

### 6. Shaders

Single new metal file `AIGame.metal` containing:

- `aigame_terrain_vertex` / `aigame_terrain_fragment`
- `aigame_obstacle_vertex` / `aigame_obstacle_fragment`
- `aigame_agent_vertex` / `aigame_agent_fragment`

Existing shader compilation flow in `MetalVisualizationRenderer` (single
`makeDefaultLibrary()`) picks them up automatically once the file is in the
Xcode app target. **`xcodegen generate` must be run after adding the metal
file**, per `CLAUDE.md`.

## Wiring (the same direction every feature touches)

1. **Domain types**: `Sources/Domain/AIGame/` (per layout above).
2. **L10nKey**: add `case sceneAIGame = "toolbar.scene.aigame"` after
   `sceneKaleidoscope` (line ~15 of `L10nKey.swift`).
3. **SceneKind**: extend the enum to include `.aigame`. Update the rawValue
   set in `SceneKind.swift`:
   ```swift
   public enum SceneKind: String, CaseIterable, Equatable, Hashable, Sendable {
       case bars, scope, alchemy, tunnel, lissajous, radial, rings,
            synthwave, spectrogram, milkdrop, kaleidoscope, aigame
   }
   ```
4. **Localizable.xcstrings**: add the `toolbar.scene.aigame` key with `en`
   `"AI Game"` and `es` `"Juego IA"`. (Missing keys do not crash but render
   the raw key — lint by inspection.)
5. **Renderer**:
   - Add `renderer.sceneBuilders[.aigame] = …` near line 111 of
     `MetalVisualizationRenderer.swift`.
   - Add `case .aigame: scene = AIGameScene()` in `buildScene` (line ~137).
   - Add `case .aigame: (materialize(.aigame) as? AIGameScene)?.randomize();
     return "AI Game"` in `randomizeCurrent()` (line ~240).
6. **Toolbar / scene picker**: existing `SceneKind.allCases` driven UI picks
   it up automatically. Verify the picker uses `L10nKey.sceneAIGame` for the
   label.
7. **Settings → Default scene picker**: same — driven by `allCases`.
8. **CompositionRoot**: no change. The scene is wired through the renderer's
   builder map like every other scene.

## Error handling

The Domain sim is total: there are no IO failures inside it. The single
defensive path is `NeuralNetwork.init(genome:)` which throws
`AIGameError.invalidGenomeLength` if a caller hands it a wrong-sized array;
this is caught and asserted in `Population` since population owns genome
production. Render-time failures fall through the existing
`materialize(_:)`'s try/catch, logged to `Log.render`.

## Testing

Domain (Swift Package, runs in <1s, no Apple frameworks):

| Test | What it pins |
|---|---|
| `NeuralNetworkTests.test_neuron_budget_within_10` | `NN.processingCount <= NN.neuronBudget` |
| `NeuralNetworkTests.test_throws_on_wrong_genome_length` | Bad input rejected |
| `NeuralNetworkTests.test_forward_outputs_in_unit_range` | Sigmoid bounds |
| `NeuralNetworkTests.test_forward_is_deterministic_for_fixed_genome` | Same in → same out |
| `GenomeTests.test_crossover_produces_correct_length` | Length invariant |
| `GenomeTests.test_mutation_with_zero_rate_is_identity` | Mutation rate honored |
| `GenomeTests.test_mutation_clamps_to_bounds` | Weights stay in `[-2, 2]` |
| `WorldTests.test_terrain_is_deterministic_for_fixed_seed` | RandomSource injection works |
| `WorldTests.test_obstacle_spawn_respects_min_spacing` | High-tempo carpet bomb not allowed |
| `WorldTests.test_pit_obstacle_appears_only_when_bass_is_high` | Music coupling |
| `AgentTests.test_agent_dies_on_spike_collision` | Collision math |
| `AgentTests.test_agent_does_not_double_jump` | Jump edge-detect |
| `AgentTests.test_fitness_grows_with_distance` | Fitness function |
| `PopulationTests.test_evolves_when_all_dead` | Generation increments + elites preserved |
| `PopulationTests.test_initial_generation_is_one` | First-frame state |

Application: nothing — there is no use case.

Infrastructure / app target: smoke test only —
`AudioVisualizerTests/AIGameSceneSmokeTests.test_scene_builds_and_renders_one_frame`
asserts the scene materializes without error. (Existing scenes do the same.)

## Performance budget

| Item | Budget | Notes |
|---|---|---|
| `Population.step` per frame | ≤ 50 µs | 6 agents × 4-6-2 NN dot products + simple physics |
| `World.advance` per frame | ≤ 30 µs | terrain shift + spawn check |
| Vertex throughput | trivial | terrain ≤ 256 quads, obstacles ≤ 8, agents 6 |
| Total Metal time | ≤ 1.5 ms | well below the 8 ms 120 Hz budget |

These numbers are loose ceilings; the scene is dramatically lighter than
Alchemy's 120k-particle compute pass, which is the existing high-water mark.

## Reduce-motion mode

When `UserPreferences.reduceMotion == true`:

- Disable beat camera shake (`cameraOffset = .zero`).
- Halve `worldScrollSpeed`.
- Disable obstacle spawn-rate amplification by mid (use a fixed `spawnP =
  0.25`).

This is consistent with how other scenes interpret the preference.

## Open risks

1. **NN size feels arbitrary.** Six hidden neurons may be enough to learn
   "jump just before a spike" within one song; if it's not, evolution looks
   stuck. We accept this — visible "trying and failing" *is* the show. If
   playtesting feels dead, the only knob to turn is `mutation rate / sigma`
   (no architectural change).
2. **Beat-driven obstacle spawn at very low BPM** could produce long empty
   stretches. Mitigation: `minSpacing` upper-bounds the wait, not a lower
   bound — but if `bpm = 0` (unknown) we use `60` as a default for spacing
   only. Verify with a slow-tempo track.
3. **Pit obstacles need the agent to actually fall**. The current physics
   snap-to-ground would make pits unreachable as deaths. Implementation must
   omit ground at the pit's x-range so `groundY` is whatever the terrain says
   (which can be far below 0), not the obstacle top.

## Out of scope (deferred)

- Reward shaping / score curriculum.
- Multiple game modes.
- Player input.
- Variable population size in settings.
- A 3D variant.

---

# Amendment 2026-05-14 — persistence + click events + seeded export

Three additions on top of the original design (above). The base architecture
holds; this section documents the deltas.

## Goals (additive)

1. **Persist learned AI state.** A user can save the current population's
   genomes (with generation + best fitness) to disk and restore them later.
2. **Random "world events" on click.** While the AI Game scene is active, a
   canvas click (and the existing keyboard randomize shortcut) fires one of N
   randomly-picked *events* that perturb the run, instead of doing a hard
   reset. The hard reset still happens implicitly when you switch scenes
   away and back.
3. **Seeded exports.** When exporting a video of the AI Game scene, the user
   may pick a previously-saved snapshot to seed the population so the AI
   starts the export already-trained.

## Locked decisions (additive)

| Question | Choice |
|---|---|
| Save trigger | Manual button **+ silent auto-save every 5 generations** to a single rolling slot id `"auto"` |
| Storage location | `Application Support/AudioVisualizer/AIGameProgress/<uuid>.json` (in-sandbox) |
| Snapshot fields | `id (UUID)`, `label (String)`, `createdAt (Date)`, `generation (Int)`, `bestFitness (Float)`, `genomes ([Genome])`, `worldSeed (UInt64)` |
| Default label | `"Gen N · yyyy-MM-dd HH:mm"` |
| Click semantics in `.aigame` | Canvas tap **and** existing randomize shortcut → `triggerRandomEvent()` (never hard-reset) |
| Hard reset | Implicit on scene re-build (switch away + back). No separate UI. |
| Events (6) | `catastrophicMutation`, `cull`, `jumpBoost(5s)`, `earthquake`, `bonusObstacleWave`, `lineageSwap` |
| Toast text | Localized event name (re-uses existing "randomize" toast surface) |
| Export seed UI | "Starting AI" picker in the Export sheet, **shown only when the chosen scene == `.aigame`**. Default is "Random / fresh". |
| Other scenes' click | Unchanged — they keep `randomize()` |

## Persistence model

### Domain

```
Sources/Domain/AIGame/
  ValueObjects/
    AIGameProgress.swift         // id, label, createdAt, generation, bestFitness, genomes, worldSeed
  Ports/
    AIGameProgressStoring.swift  // list / save / load / delete
  Errors/
    AIGameError.swift            // + .progressNotFound(UUID), .progressIOFailed(String)
```

```swift
public struct AIGameProgress: Equatable, Sendable, Codable {
    public let id: UUID
    public let label: String
    public let createdAt: Date
    public let generation: Int
    public let bestFitness: Float
    public let genomes: [Genome]
    public let worldSeed: UInt64
}

public protocol AIGameProgressStoring: Sendable {
    func list() throws -> [AIGameProgress]
    func save(_ progress: AIGameProgress) throws -> AIGameProgress
    func load(id: UUID) throws -> AIGameProgress
    func delete(id: UUID) throws
}
```

`Genome` already conforms to `Equatable + Sendable`; we add `Codable` (its
single `[Float]` field is already trivially codable).

### Application

```
Sources/Application/UseCases/
  SaveAIGameProgressUseCase.swift     // execute(label:, snapshotProvider:) -> AIGameProgress
  ListAIGameProgressUseCase.swift     // execute() -> [AIGameProgress]
  LoadAIGameProgressUseCase.swift     // execute(id:) -> AIGameProgress
  DeleteAIGameProgressUseCase.swift   // execute(id:)
```

Each use case takes the `AIGameProgressStoring` port via constructor
injection, exactly the same pattern as existing use cases.

### Infrastructure

```
AudioVisualizer/Infrastructure/Persistence/
  FileSystemAIGameProgressStore.swift
```

- Storage root: `FileManager.applicationSupportDirectory.appendingPathComponent("AudioVisualizer/AIGameProgress")`. Created on first use.
- Format: one JSON file per snapshot named `<id>.json`, encoded with
  `JSONEncoder` (default settings + `.iso8601` dates).
- `list()` enumerates the directory, decodes each file, and **drops** any
  file that fails to decode (with an `os.log` warning) so a corrupted file
  doesn't crash the picker.
- Thread-safety: all I/O goes through one `DispatchQueue` ("aigame.progress")
  serial queue; the use cases call into it via `await`.

### Domain extensions

`Population` gains:

```swift
/// Build a snapshot of the current generation that can be persisted and
/// later passed back into `init(restoring:source:)` to resume.
public func snapshotProgress(label: String) -> AIGameProgress

/// Construct a population from a saved snapshot. Honors the snapshot's
/// `worldSeed` so the terrain feel is comparable; agents start at world
/// origin with `generation` carried over and the loaded genomes installed.
public init(restoring snapshot: AIGameProgress, source: RandomSource)
```

`AIGameScene` gains:

```swift
/// Pre-load the population from a saved snapshot. Must be called before the
/// first `update(...)`; otherwise the call is a no-op (the live population
/// is already running).
func setSeedProgress(_ progress: AIGameProgress)

/// Trigger one randomly-picked AIGameEvent. Returns the localized display
/// label so the existing toast can show what happened.
@discardableResult
func triggerRandomEvent() -> String
```

## Random event roulette

```swift
public enum AIGameEvent: Equatable, Sendable, CaseIterable {
    case catastrophicMutation     // every alive agent: mutate(rate=1.0, sigma=0.5)
    case cull                     // half the alive agents die immediately
    case jumpBoost                // jumpImpulse *= 1.5 for the next 5 sim-seconds
    case earthquake               // re-seed terrain noise + clear all obstacles
    case bonusObstacleWave        // spawn 3 obstacles in quick succession
    case lineageSwap              // crossover every alive agent with the best dead one
}

public enum RandomEventRoulette {
    public static func pick(using r: RandomSource) -> AIGameEvent {
        let i = Int(r.nextUnit() * Float(AIGameEvent.allCases.count)) % AIGameEvent.allCases.count
        return AIGameEvent.allCases[i]
    }
}
```

Application of an event mutates `Population` in-place via:

```swift
public func applyEvent(_ event: AIGameEvent, source: RandomSource)
```

Effects (in `Population`):

| Event | Effect |
|---|---|
| `catastrophicMutation` | For each alive agent's genome: `mutate(rate: 1.0, sigma: 0.5)` and rebuild its `NeuralNetwork`. |
| `cull` | Mark `floor(aliveCount / 2)` random alive agents `alive = false`. Their fitness is frozen at the death frame so the next evolution can still inherit from them. |
| `jumpBoost` | Set `population.jumpBoostUntilSimTime = currentSimTime + 5.0`. `Agent.step` reads this multiplier and uses `jumpImpulse * 1.5` while active. (Plumbed via `AudioDrive`-adjacent struct `RuntimeOverrides`.) |
| `earthquake` | `world.reseedTerrain()` (rotates `worldSeed`) and `world.obstacles.removeAll()`. `lastSpawnX = -.infinity`. |
| `bonusObstacleWave` | Append 3 spike obstacles at `cameraX + 1.4`, `+1.7`, `+2.0` with `height = 0.25`. `lastSpawnX` updated to the last one. |
| `lineageSwap` | Identify the highest-fitness dead agent (or, if none, the lowest-fitness alive agent); for every alive agent, replace its genome with `crossover(self, donor)` and rebuild the network. |

Click → event flow:

```
RootView.onTapGesture
  → vm.randomizeCurrent()
    → renderer.randomizeCurrent()
      → switch currentKind {
          case .aigame: return aigameScene.triggerRandomEvent()  // returns localized event name
          ... other scenes unchanged ...
        }
  → toast displays the returned label (existing UI, no change)
```

## Seeded export

### Domain port extension

`OfflineVideoRendering.begin(...)` gains an optional parameter:

```swift
func begin(output: URL, options: RenderOptions, scene: SceneKind,
           palette: ColorPalette,
           aiGameProgress: AIGameProgress? = nil) throws
```

(Default value preserves source-compatibility for non-AI-Game callers.)

### Application use case

`ExportVisualizationUseCase.execute(...)` gains:

```swift
public func execute(audio: URL,
                    output: URL,
                    scene: SceneKind,
                    palette: ColorPalette,
                    options: RenderOptions,
                    aiGameProgress: AIGameProgress? = nil) -> AsyncStream<ExportState>
```

It passes `aiGameProgress` through to `renderer.begin(...)`. No other logic
changes.

### Infrastructure adapter

`AVOfflineVideoRenderer.begin(...)`:

1. Build the scene as today.
2. **If `scene == .aigame` and `aiGameProgress != nil`**: down-cast the built
   scene to `AIGameScene` and call `setSeedProgress(progress)` before the
   first `consume`.
3. Otherwise, behavior is unchanged.

### Presentation

`ExportViewModel`:

- New `@Published var availableProgresses: [AIGameProgress] = []` populated
  on sheet open via `ListAIGameProgressUseCase`.
- New `@Published var selectedProgressID: UUID? = nil` (nil = "Random /
  fresh").
- Picker only renders when `selectedScene == .aigame`.

`ExportSheetView`:

- New section `"export.section.aiSeed"` (visible iff scene is `.aigame`)
  containing a labelled `Picker` whose options are `["Random / fresh"] +
  saved.map { $0.label }`.

## Save/Load UI in the live preview

A small toolbar group, shown only when `vm.currentScene == .aigame`:

- **`Save AI`** button (label `aiGameSaveButton`). On click, calls
  `vm.saveAIProgress()` which:
  1. Asks the renderer for the live snapshot via
     `aigameScene.population.snapshotProgress(label:)` (label auto-generated:
     `"Gen \(N) · \(formattedDate)"`).
  2. Calls `SaveAIGameProgressUseCase.execute`.
  3. Surfaces the existing toast: "Saved · {label}".
- **`Load AI`** menu (label `aiGameLoadMenu`) listing `availableProgresses`
  by `label`. Selecting an entry calls `vm.loadAIProgress(id:)`, which:
  1. Calls `LoadAIGameProgressUseCase.execute(id:)`.
  2. Calls `aigameScene.setSeedProgress(progress)`. Because `setSeedProgress`
     is a no-op when the scene is already running, **the load also calls
     `aigameScene.rebuildPopulation()`** (new method that re-runs the same
     init path used at scene-build time, this time honoring the seed).

Auto-save: `Population.step(...)` fires `onGenerationDidIncrement` (new
closure callback). `AIGameScene` subscribes; on every 5th increment it builds
a snapshot with `label = "auto"` and writes it via
`SaveAIGameProgressUseCase` (auto-save uses a fixed `id` so it overwrites in
place). The save call is fire-and-forget; failures are logged, not surfaced.

## Updated tests (deltas)

Domain (additions):

| Test | What it pins |
|---|---|
| `AIGameProgressTests.test_codable_round_trip` | JSON encode + decode preserves all fields |
| `RandomEventRouletteTests.test_pick_returns_each_event_for_uniform_input` | Roulette is uniform over `[0,1)` |
| `PopulationTests.test_snapshotProgress_round_trip_via_restoring_init` | snapshot → restore preserves genomes + generation |
| `PopulationTests.test_apply_catastrophicMutation_changes_all_alive_genomes` | Mutation hits every alive agent |
| `PopulationTests.test_apply_cull_kills_half_of_alive` | Cull math |
| `PopulationTests.test_apply_jumpBoost_sets_window` | jumpBoostUntilSimTime is set |
| `PopulationTests.test_apply_earthquake_clears_obstacles_and_reseeds_terrain` | Earthquake effect |
| `PopulationTests.test_apply_bonusObstacleWave_appends_three` | Three obstacles spawned |
| `PopulationTests.test_apply_lineageSwap_changes_alive_genomes_when_donor_exists` | Donor-driven crossover |
| `PopulationTests.test_onGenerationDidIncrement_fires_after_evolution` | Callback fires |

Infrastructure (additions):

| Test | What it pins |
|---|---|
| `FileSystemAIGameProgressStoreTests.test_save_then_list_returns_one` | Round-trip on disk |
| `FileSystemAIGameProgressStoreTests.test_corrupted_file_is_skipped_in_list` | Resilience |
| `FileSystemAIGameProgressStoreTests.test_delete_removes_file` | Cleanup |
| `AVOfflineVideoRendererTests.test_aigame_export_with_progress_seeds_population` | End-to-end seed honored |

Application (additions):

| Test | What it pins |
|---|---|
| `SaveAIGameProgressUseCaseTests.test_assigns_id_and_createdAt_when_missing` | UUID + timestamp generated |
| `LoadAIGameProgressUseCaseTests.test_throws_when_id_unknown` | Maps store error to domain error |
| `ExportVisualizationUseCaseTests.test_passes_aiGameProgress_through_to_renderer` | Plumbing |

## L10n keys (additions)

```
toolbar.scene.aigame                  // already in original spec
toolbar.aigame.save                   // "Save AI"     / "Guardar IA"
toolbar.aigame.loadMenu               // "Load AI ▾"   / "Cargar IA ▾"
toolbar.aigame.loadMenu.empty         // "(no saved progress yet)"  / "(sin progreso guardado)"
overlay.aigame.saved                  // "Saved · %@"  / "Guardado · %@"
overlay.aigame.loaded                 // "Loaded · %@" / "Cargado · %@"

aigame.event.catastrophicMutation     // "Catastrophic mutation!" / "¡Mutación catastrófica!"
aigame.event.cull                     // "Cull!"          / "¡Purga!"
aigame.event.jumpBoost                // "Jump boost!"    / "¡Salto turbo!"
aigame.event.earthquake               // "Earthquake!"    / "¡Terremoto!"
aigame.event.bonusObstacleWave        // "Obstacle wave!" / "¡Oleada de obstáculos!"
aigame.event.lineageSwap              // "Lineage swap!"  / "¡Cambio de linaje!"

export.section.aiSeed                 // "Starting AI"    / "IA inicial"
export.aiSeed.fresh                   // "Random / fresh" / "Aleatoria / desde cero"
```

## Open risks (additions)

1. **Schema drift across versions.** A v2 build that adds NN inputs will
   read an old snapshot's genomes with the wrong length. Mitigation: stamp
   `AIGameProgress` with `genomeLength` on save; on load, throw
   `AIGameError.invalidGenomeLength` if it doesn't match the current
   `Genome.expectedLength`. UI surfaces a non-fatal error in the picker.
2. **Sandbox container path drift between debug + release.** Both build
   configurations land in the same per-app container, so this is a
   non-issue today; documented here so a future `RELEASE_PRODUCT_BUNDLE_IDENTIFIER`
   change isn't a surprise.
3. **Auto-save under heavy generation churn.** If a scene burns through 5
   generations in <1 s (unlikely but possible with very harsh events), the
   fire-and-forget save can queue up. Mitigation: the serial dispatch queue
   in `FileSystemAIGameProgressStore` naturally serialises; we simply accept
   a slightly stale "auto" slot.
