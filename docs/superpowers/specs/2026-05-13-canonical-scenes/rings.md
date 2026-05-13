# Rings — canonical sonar-ping rewrite spec

## Visual goal

A pitch-black field on which each detected beat **drops a ring** at the screen
center that **expands outward at a fixed velocity**, **fades exponentially**,
and **glows like a wavefront** (bright thin leading edge, soft 1/r halo). The
overall feel should read as a sonar ping or as a stone landing in still water:
the ring is a discrete event you can count, not a continuous wobble. Between
beats the scene must never look dead, so a slow continuous spawn (~0.5 Hz)
keeps the surface alive. Optional spectrum-driven angular warping makes the
ring "breathe" along its circumference without breaking its identity.

References:
- iTunes / Apple Music background visualizers — discrete beat-pulsed
  concentric ripples on a near-black field.
- Shadertoy *Ripple music visualizer* (XdVcWK) and *VE — Bass Warp Rings*
  (NfS3Wh) — pooled rings with audio-warped circumference.
- Keijiro's `SonarFx` and the Godot `sonar-effect-shader` — the canonical
  `r(t) = speed * (t − birth)` expanding-band-of-visibility formulation.

## Inputs

Each frame the scene receives:

| Input | Type | Use |
|---|---|---|
| `spectrum.bands` | `[Float]` (64) | low/mid/high tilt for warp + palette pick |
| `spectrum.rms`   | `Float` | gentle inner-halo brightness, idle spawn gating |
| `waveform`       | `[Float]` (1024) | unused (kept for parity, no scope here) |
| `beat`           | `BeatEvent?` | **primary spawn trigger**, `beat.strength ∈ [0,1]` |
| `dt`             | `Float` | integration step for `time` and per-ring radius |
| `uniforms`       | `time, aspect, rms, beatStrength` | passed through to fragment |

## Algorithm step-by-step

### 1. Ring state (CPU-side particle)

Each ring is a particle with the fields below. Birth-time-based; **do not**
integrate radius on the CPU (it accumulates float drift and makes pausing/
seeking incoherent). Compute radius from `time − birth_time` so the system
remains deterministic given `time`.

```swift
struct Ring {
    var birthTime: Float    // absolute time at spawn
    var intensity: Float    // ∝ beat.strength at spawn, in [0,1]
    var paletteU: Float     // sampled once at spawn, stable for the life of the ring
    var speed: Float        // radial velocity in NDC-x units per second
    var lifetime: Float     // seconds until alpha is effectively zero
    var bandIndex: Int      // which FFT band drives this ring's warp (rotates per spawn)
}
```

### 2. Spawn rule

- **On every `beat`**: `intensity = clamp(0.35 + 0.65 * beat.strength, 0, 1)`.
  Capacity is fixed at `MAX_RINGS = 16`. If full, **recycle the oldest**
  (`argmin(birthTime)`), not the first inserted — keeps newest rings.
- **Idle continuous spawn**: when no beat has fired in the last
  `idleGapSec = 1.5 s` *and* `rms < 0.02`, fire a ring with
  `intensity = 0.20` every `1 / idleHz` seconds where `idleHz = 0.5`. This
  guarantees a visible event roughly every 2 s even on silence.
- **`paletteU`** is drawn from a stratified rotation: `paletteU = (spawnIndex
  * 0.382) mod 1` (golden-ratio shuffle) → consecutive rings get distinct
  hues without random clumping.
- **`speed`** is jittered by `±15%` around `speedBase = 0.55` so two rings
  spawned together visibly separate after ~0.3 s.

### 3. Radius over time (wave equation)

```
age   = time - birthTime
r(t)  = age * speed                       // NDC-x units; 0.55 ≈ "half screen / sec"
```

When `r > 1.6 * aspect` (off-screen) **or** `age > lifetime`, the ring is
retired.

### 4. Intensity fade (exponential + 1/r shockwave)

Two-component intensity so the ring both decays in time *and* dims as it
spreads (energy conservation in 2D):

```
fadeTime    = exp(-age / tau)             // tau = 1.2 s
fadeSpread  = ringR0 / (r + ringR0)        // ringR0 = 0.05; clamps the inner spike
alpha       = intensity * fadeTime * fadeSpread
```

`fadeSpread` matters: without it a fresh small ring looks identical to an
aged big ring; with it the new ring is visibly *hotter*, which is what
"shockwave" reads as.

### 5. Ring SDF and antialiased line

Sample-space line, antialiased to one pixel:

```glsl
float d  = abs(length(p) - r);             // distance to the ideal circle
float w  = w0 + age * growRate;            // w0 = 0.004, growRate = 0.010
float aa = fwidth(d) * 1.0;                // one-pixel feather
float band = 1.0 - smoothstep(w - aa, w + aa, d);
```

`w` grows so older rings turn from a sharp line into a soft band — visually
matches the dispersion of a real wave packet. **Do not** use a Gaussian
`exp(-d²/w²)` alone; it has no hard leading edge and washes out the wavefront.
Combine: a sharp `smoothstep` core + a wide `1/d` glow:

```glsl
float core = band;                          // hard leading edge
float glow = clamp(0.010 / max(d, 1e-3), 0.0, 1.0) * 0.6;
float ringI = (core + glow) * alpha;
```

### 6. Audio modulation on ring shape

Warp the circle along `θ = atan2(p.y, p.x)` using two harmonics from the
spectrum so the ring breathes without losing its circle identity:

```glsl
float theta = atan2(p.y, p.x);
float r_warp = r
    + bass    * 0.020 * sin(8.0  * theta + ringPhase)
    + treble  * 0.005 * sin(64.0 * theta + ringPhase);
float d = abs(length(p) - r_warp);
```

Where `bass = avg(bands[0..4])` and `treble = avg(bands[48..63])`, normalized
to roughly `[0,1]` on the Swift side. `ringPhase` is `paletteU * 2π` so rings
don't all warp in phase.

### 7. Pool layout (CPU → GPU)

Fixed-capacity `MAX_RINGS = 16`. Pack into a `MTLBuffer` of 16 `float4`s:
`(radius, alpha, ageNormalized, paletteU)`. CPU computes `radius` and
`alpha`; fragment shader iterates the fixed 16 slots with `if (alpha <
1e-4) continue;`. **No dynamic `Array.remove(at:)`** in the hot path — use
an in-place swap-with-last + decrement count, or a free-list. The current
implementation re-uploads every frame, which is fine at 16 slots × 16 B.

### 8. Color

A 1-D palette texture sampled at `paletteU`. The palette should be
chromatically saturated (cyan → magenta → orange) so consecutive
golden-ratio-spaced rings produce a pleasing chord. Inner halo uses
`palette.sample(0.5).rgb * rms * 0.15` to give the center a faint matching
tone instead of pure white.

## Critical numerical constants

| Name | Value | Rationale |
|---|---|---|
| `MAX_RINGS` | 16 | Bounds fragment loop; visually plenty |
| `speedBase` | 0.55 NDC/s | ≈ half screen-width per second — readable as a single event |
| `speedJitter` | ±15 % | breaks formation when bursts hit |
| `tau` | 1.2 s | matches a 2 Hz beat density without overlap |
| `lifetimeSec` | 3.0 s | hard cutoff once `exp(-3/1.2) ≈ 0.08` |
| `w0` | 0.004 | one-pixel-ish line on 1080p |
| `growRate` | 0.010 / s | line doubles by ~0.4 s (wave packet feel) |
| `ringR0` (1/r clamp) | 0.05 | prevents singularity at birth |
| `idleHz` | 0.5 | one idle ring every 2 s |
| `idleGapSec` | 1.5 | only idle-spawn after a quiet stretch |
| `idleRmsGate` | 0.02 | suppress idle when audio is present |
| `glowGain` | 0.6 | balance between glow and core (≤ 1.0 to avoid blow-out) |
| `bassWarpAmp` | 0.020 | ≤ 2 % of screen — visible but ring stays a ring |
| `trebleWarpAmp` | 0.005 | high-frequency shimmer only |

## Common pitfalls

1. **One ring per frame == 1 ring total at any time.** Drawing the
   "current" ring instead of looping `N` pooled rings gives a single wobble,
   not a sonar field. The fragment **must** iterate the pool.
2. **No exponential fade.** Linear `(1 − age/lifetime)` fade looks like
   stage lighting, not water. Use `exp(-age/τ)`.
3. **Uniform line width.** A constant `w` makes every ring look identical
   regardless of age — the eye can't separate young from old. Grow `w` with
   age.
4. **Integrating `radius += speed * dt` on the CPU.** Float drift; resumes
   incoherently after pause; harder to reason about. Always recompute from
   `time − birth_time`.
5. **Gaussian-only ring profile.** No hard leading edge → soft blobs. Use
   `smoothstep` core *plus* `1/d` glow.
6. **`Array.remove(at:)` inside the per-frame loop.** O(n) shift per dead
   ring; not RT-friendly. Swap-with-last or use a free-list.
7. **Random palette per ring.** Adjacent rings get visually identical hues
   ~30 % of the time. Use a golden-ratio rotation instead.
8. **Spawn-only-on-beats.** Quiet passages look broken. Idle spawn at
   0.5 Hz when RMS is low.
9. **No 1/r intensity falloff.** All rings look equally bright regardless of
   age → loses the "shockwave from a point" cue.
10. **Saturating alpha to 1.0 in fragment with additive blend.** Dense
    overlap blooms out. Either clamp per-ring contribution *or* switch to
    `oneMinusSourceAlpha` blending (current code uses the latter — correct).

## Comparison with current implementation

Current files:

- `AudioVisualizer/Infrastructure/Metal/Scenes/RingsScene.swift`
- `AudioVisualizer/Infrastructure/Metal/Shaders/Rings.metal`

What's already good:

- Pool exists (`maxRings = 32`, `Ring` struct, packed `float4` upload).
- Beat spawn + ambient timer present.
- Additive-like blending with `sourceRGBBlendFactor = .one`,
  `destinationRGBBlendFactor = .oneMinusSourceAlpha`.
- Palette texture sampled by `paletteU`.
- Fragment iterates the pool — not a single-ring wobble.

Gaps vs canonical:

| # | Gap | Where |
|---|---|---|
| G1 | Radius integrated on CPU (`radius += speed * dt`) instead of `age * speed` from `birthTime`. Float drift; can't easily recompute on pause/seek. | `RingsScene.update` |
| G2 | Fade is **quadratic ease-in** (`1 − t²`), not exponential. Looks like a stage cue, not a wave. | `RingsScene.update` |
| G3 | **No 1/r shockwave falloff.** Young and old rings have the same intensity at their leading edge. | `Rings.metal` fragment |
| G4 | Ring profile is **Gaussian only** (`exp(-d²/w²)`). No hard wavefront, no glow halo separation. | `Rings.metal` fragment |
| G5 | **No spectrum warping** — perfectly circular regardless of audio. | `Rings.metal` fragment + `RingsScene` upload |
| G6 | Palette `paletteU` is **uniform-random**, producing clumps. | `RingsScene.spawn` |
| G7 | Spawn uses **`removeFirst()`** (O(n)) when at capacity and `remove(at:)` inside the update loop. | `RingsScene.update`, `.spawn` |
| G8 | Ambient cadence depends on `rms` (faster when loud), the opposite of what you want — idle spawn should be a *quiet-room* feature. | `RingsScene.update` |
| G9 | `maxRings = 32` is generous; 16 is plenty and halves fragment work. Per-pixel loops of 32 with `exp` each is the dominant cost. | both files |
| G10 | Width growth is age-relative-to-lifetime, not age-in-seconds — feels arbitrary across lifetimes. Should be absolute `w0 + age * growRate`. | `RingsScene.update` |

## Concrete fix list

1. **Store `birthTime` per ring; derive `radius = (time − birthTime) * speed`
   in `update`.** Remove the `radius += speed * dt` integration. Keeps
   `speed`/`lifetime`/`paletteU` immutable per ring.
2. **Replace the `1 − t²` fade with `alpha = intensity * exp(-age / 1.2) *
   ringR0 / (radius + ringR0)`.** The second factor is the 1/r shockwave.
   Drop `lifetimeBase`; use a constant `lifetimeSec = 3.0` cutoff.
3. **Rewrite the fragment ring profile** as `smoothstep` core plus `1/d`
   glow (see §5). Keep the per-ring `width` upload, but interpret it as
   `w = w0 + age * growRate` computed on the CPU; `w0 = 0.004`,
   `growRate = 0.010`.
4. **Add bass/treble warp.** On the Swift side, compute
   `bass = avg(bands[0..4])`, `treble = avg(bands[48..63])`, pass as two
   floats in `RingsUniforms`. In the fragment, replace `length(p) - r`
   with `length(p) - (r + bass*0.020*sin(8θ+φ) + treble*0.005*sin(64θ+φ))`
   where `φ = paletteU * 2π`.
5. **Replace random `paletteU` with golden-ratio rotation.** Keep a
   `spawnCounter: Int`; set `paletteU = Float(spawnCounter) * 0.6180339
   .truncatingRemainder(dividingBy: 1)`.
6. **Pool management without O(n) shifts.** Use a fixed `[Ring?]` of size
   `MAX_RINGS = 16` and a `nextSlot: Int` cursor; on spawn, write into the
   slot with the oldest `birthTime` (linear scan of 16 is fine).
   In `encode`, iterate all 16 slots, skip nil/expired.
7. **Cut `MAX_RINGS` from 32 to 16** (and update the buffer length +
   shader `for` bound). Visually identical, 2× cheaper per fragment.
8. **Fix idle-spawn semantics.** Idle only when `rms < 0.02` *and* no beat
   for `idleGapSec = 1.5 s`. Interval is a flat `1/idleHz = 2.0 s`, not
   `rms`-modulated.
9. **Constants table moves to a `struct RingsTuning` at the top of
   `RingsScene.swift`** (or, ideally, into `Sources/Domain` if we want it
   testable — values are pure data). The `randomize()` knob should jiggle
   `speedBase`, `tau`, and `bassWarpAmp` only — not lifetime, not width
   growth.
10. **Inner halo uses palette mid-tone** (`palette.sample(0.5)`) not white
    — keeps the screen tonally consistent with the rings.

## References

- Inigo Quilez — 2D distance functions (canonical `sdCircle`, ring formulas):
  https://iquilezles.org/articles/distfunctions2d/
- Inigo Quilez — Distance article (smoothstep AA on SDFs):
  https://iquilezles.org/articles/distance/
- Shadertoy — *Ripple music visualizer* (XdVcWK):
  https://www.shadertoy.com/view/XdVcWK
- Shadertoy — *VE — Bass Warp Rings* (NfS3Wh, concentric rings warped by bass):
  https://www.shadertoy.com/view/NfS3Wh
- Shadertoy — *circle and ripple* (XlyfRc):
  https://www.shadertoy.com/view/XlyfRc
- Keijiro Takahashi — *SonarFx* (Unity sonar/wave full-screen effect):
  https://github.com/keijiro/SonarFx
- Godot — *Sonar Effect Shader* (`r(t) = speed * t mod interval`, residual
  width fade): https://godotshaders.com/shader/sonar-effect-shader/
- inspirnathan — *Glow shader in Shadertoy* (the `0.01 / d` glow term):
  https://inspirnathan.com/posts/65-glow-shader-in-shadertoy/
