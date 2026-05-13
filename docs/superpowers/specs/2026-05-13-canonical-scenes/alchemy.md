# Alchemy — canonical audio-reactive GPU particle scene

## Visual goal

A swirling, *alive*-feeling cloud of 100k+ glowing point sprites whose motion is
driven by a divergence-free curl-noise flow field that is itself modulated by
the music: bass widens and intensifies the field, mids change the swirl
frequency, highs spawn short-lived "sparkle" particles, and beats deliver a
visible radial impulse plus a brief color flash. Trails are produced by an
additive ping-pong feedback pass with a per-frame multiply ~0.94 so motion
leaves luminous wakes without saturating the screen. Reference look: Magic
Music Visuals' particle scenes, Plane9's "Aurora"/"Plasma" scenes, Winamp AVS
"Superscope" + dynamic-movement combinations, and curl-noise particle demos.

References:
- https://emildziewanowski.com/curl-noise/ (curl-noise dissection, exact 2D code)
- https://tympanus.net/codrops/2023/12/19/creating-audio-reactive-visuals-with-dynamic-particles-in-three-js/ (Codrops audio-reactive particles in Three.js)
- https://www.cs.ubc.ca/~rbridson/docs/bridson-siggraph2007-curlnoise.pdf (Bridson 2007, original curl-noise paper)
- https://www.plane9.com/ (Plane9 scene reference; visual target)

## Inputs (per frame)

| Name | Type | Range | Source |
|---|---|---|---|
| `spectrum.bands` | `[Float]` length 64 | `[0, ~]` linear FFT magnitude | `VDSPSpectrumAnalyzer` |
| `waveform` | `[Float]` length 1024 | `[-1, 1]` | ring buffer |
| `beat` | `BeatEvent?` | `strength ∈ [0,1]` | `EnergyBeatDetector` |
| `dt` | `Float` | `~1/60..1/120` s | render loop |
| Uniforms | — | `time, aspect, rms, beatStrength` | scene |

Derived audio scalars (computed CPU-side, smoothed per frame):

- `bass`   = mean of bands `[0, 8)`           (≈0–250 Hz)
- `mid`    = mean of bands `[8, 32)`          (≈250 Hz–4 kHz)
- `treble` = mean of bands `[32, 64)`         (≈4–22 kHz)
- One-pole envelope follower per band:
  `e ← max(x, e * decay)` with `decay_bass=0.88, decay_mid=0.85, decay_treble=0.80`
- Beat envelope: `beatEnv = max(beatEnv, beat.strength); beatEnv *= 0.90`

## Algorithm

### 1. Particle state (per-particle, SoA in one storage buffer)

```
struct Particle {
    float2 pos;     // NDC-ish, range roughly [-1.6, 1.6]
    float2 vel;     // units per second
    float  age;     // [0, lifetime), increasing
    float  life;    // total lifetime in seconds (0.8..1.5)
    float  seed;    // [0,1), per-particle hash key
    uint   kind;    // 0 = normal, 1 = sparkle (treble-spawned)
};
```

**Counts**: `N = 120_000` normal + up to `N_spark = 8_192` sparkle particles.
At these counts a single compute dispatch (`dispatchThreads(N, …)`) runs in
~0.4 ms on Apple Silicon; rendering 120k instanced quads adds ~1.2 ms.

### 2. Curl-noise force field

Use the **2D stream-function form** of curl noise (Bridson 2007, §3):

> In 2D the potential is a scalar `ψ(p, t) = N(p, t)` and the velocity field is
> `v = curl(ψ) = (∂ψ/∂y, -∂ψ/∂x)`. This field is exactly divergence-free, so
> particles never converge to point attractors — they swirl.

Compute by central differences with `ε = 0.05..0.10` (tune so that
`ε * curlScale` is ~0.05 in noise-space — finer ε produces noise, coarser ε
produces "muddy" flow):

```metal
float2 curl(float2 p, float t) {
    const float eps = 0.07;
    float n1 = vnoise(p + float2(0, eps), t);
    float n2 = vnoise(p - float2(0, eps), t);
    float n3 = vnoise(p + float2(eps, 0), t);
    float n4 = vnoise(p - float2(eps, 0), t);
    return float2(n1 - n2, -(n3 - n4)) / (2.0 * eps);
}
```

**Noise function**: 3-octave fBm of value or simplex noise, weights
`[1.0, 0.5, 0.25]`, lacunarity `2.0`. Time evolution: pass `t * 0.15` as a 3rd
coordinate (treat as 3D noise sliced at constant z) so the field morphs
continuously instead of "shimmering" frame-to-frame.

### 3. Audio coupling

| Band | Where it goes | Formula |
|---|---|---|
| `bass`   | field magnitude + outward push | `forceScale = 0.9 + 2.0*bass + 1.5*beat` |
| `bass`   | drag (less drag → bigger wakes on bass) | `drag = mix(0.985, 0.92, bass)` |
| `mid`    | curl frequency | `q = pos * (1.4 + 1.6*mid) + seed*7.3` |
| `mid`    | swirl bias (tangential around center) | `swirl += mid * 1.2` |
| `treble` | sparkle spawn rate | `spawnRate_spark = 200 + 6000*treble` /s |
| `treble` | per-particle hue jitter | `hue += treble * 0.10 * seed` |
| `beat`   | radial impulse | `v += radialFromCenter(pos) * 0.9 * beat` (one frame) |
| `beat`   | palette phase flash | `paletteOffset += 0.05 * beat` |

The crucial rule: **all audio scalars enter as *multipliers on existing terms*,
not as direct positional displacement**. A particle whose position is set
directly from FFT magnitudes looks like an oscilloscope, not a fluid.

### 4. Integration (semi-implicit Euler)

```
a   = curl(q, t) * forceScale + tangent * swirl
v  += a * dt
v  *= drag                 // exponential damping; see "drag" above
v   = clamp(length(v), 0, vmax) * normalize(v)   // optional cap
p  += v * dt
age += dt
```

Notes:
- **Cap velocity** at `vmax = 2.5` units/s so a runaway beat impulse can't
  hurl particles off-screen for seconds.
- **Drag is applied multiplicatively**, not subtracted, so it's frame-rate
  stable: `v *= pow(dragPerSecond, dt)` is the strictly-correct form. For
  60–120 Hz frames the constant-drag approximation `v *= 0.985` is acceptable.

### 5. Spawn / despawn

Lifetime sampled at birth from `U(0.8, 1.5) s`. Respawn rules:

- `age > life`  → respawn
- `length(pos) > 1.8` → respawn
- On respawn, choose an **emitter shape** parameterized by audio:
  - normal: ring of radius `0.55 + 0.40*hash(seed,t)` around a wandering
    Lissajous attractor (`x = Ax sin(ωx t), y = Ay sin(ωy t + φ)`).
  - sparkle (`kind=1`): spawn at random point on screen with high initial
    speed in random tangential direction; lifetime `0.15..0.40 s`.

Initial velocity: tangent to the spawn ring scaled by `0.25 + 1.0*bass`, so
bass-heavy moments birth particles with visible orbital momentum.

### 6. Color

Use **IQ's cosine palette** (Inigo Quilez) for cheap, hue-rich gradients:

```
vec3 palette(float t) {
    vec3 a = vec3(0.5);
    vec3 b = vec3(0.5);
    vec3 c = vec3(1.0);
    vec3 d = vec3(0.00, 0.33, 0.67);   // "rainbow"
    return a + b * cos(6.2831853 * (c*t + d + paletteOffset));
}
```

Index `t` by a mix of **speed**, **angle around center**, and **(1 - age/life)**:

```
t = fract(angle / TAU
        + (1 - age/life) * 0.35
        + length(vel) * 0.08
        + bass * 0.25
        + seed * 0.15
        + hueShift)
```

Render with **additive blending**: `srcRGB = SRC_ALPHA, dstRGB = ONE`. Sprites
are billboard quads with a Gaussian core × halo falloff:

```
core = exp(-d² * 6.0)
halo = exp(-d * 2.5) * 0.35
alpha = (core + halo) * envelope(age/life) * intensity
```

with `envelope(u) = sin(π u)` so particles fade in at birth and out at death.

Intensity guard: `intensity = 0.30 + 0.40 * beat`. The 0.30 base is empirical:
120k additive sprites would clip white otherwise.

### 7. Trails / fade (framebuffer ping-pong)

Two offscreen color textures, A and B (BGRA8Unorm_sRGB, matching drawable).
Each frame:

1. Set render target = A.
2. Full-screen quad sampling B, output `previousColor * fade` with
   `fade = 0.945 - 0.020 * beat` (beats *shorten* the trail momentarily, which
   reads as a punchy "flash"). Clamp `fade ∈ [0.88, 0.99]`.
3. Draw all particles additively into A.
4. Composite A → drawable (or swap roles next frame). Either is fine; swapping
   is cheaper.

A subtle radial *bloom-lite* pass (4-tap box blur, weight 0.15) on the output
adds the characteristic "Magic"/Plane9 glow without a real bloom pipeline.

## Critical numerical constants

| Name | Value | Notes |
|---|---|---|
| Particle count (normal) | `120_000` | sweet spot for Apple Silicon |
| Particle count (sparkle) | `8_192` | bounded pool |
| Curl ε | `0.07` | finite-difference width in noise-space |
| Curl noise base scale | `1.4` | multiplied by `(1 + mid)` at runtime |
| Octaves of fBm | `3` | weights 1.0, 0.5, 0.25 |
| Time-evolution rate | `0.15` | noise z-coordinate speed |
| Drag per second | `0.985` | mix to `0.92` on bass |
| Velocity cap `vmax` | `2.5` units/s | prevents beat-blowout |
| Force scale base | `0.9` | + `2.0*bass + 1.5*beat` |
| Swirl bias base | `1.0` | + `1.2*mid` |
| Tangent radial coupling | `0.22 / (r + 0.25)` | softens singular pull |
| Beat impulse | `0.9 * beat` | one-frame radial kick |
| Lifetime | `0.8..1.5 s` | normal; `0.15..0.40 s` sparkle |
| Spawn radius | `0.55..0.95` | ring around attractor |
| Trail fade | `0.945` | `0.88..0.99` range |
| Beat fade boost | `-0.020` | sharper trails on beats |
| Sprite core falloff | `exp(-d²*6)` | Gaussian-ish core |
| Sprite halo | `exp(-d*2.5)*0.35` | outer glow |
| Base intensity | `0.30` | + `0.40*beat`; lower if you raise N |
| Palette type | IQ cosine | `a=b=0.5, c=1, d=(0,1/3,2/3)` |
| Attractor speeds (x,y) | `0.4..1.1` rad/s | randomized; require |Δ|>0.1 |
| Attractor amps (x,y)   | `0.40..0.70`, `0.35..0.60` | randomized |

## Common pitfalls

1. **Noise frequency too high** → particles look like TV static. Symptom:
   neighboring particles diverge wildly. Fix: `curlScale ≤ 3.5`, `ε ≥ 0.05`.
2. **No drag** → velocities accumulate from beat impulses, particles fly off
   screen forever. Always damp.
3. **No velocity cap** → a sequence of beats integrates into a single huge
   `v`. Cap to `vmax`.
4. **Audio drives position directly** → looks like an oscilloscope, not a
   visualizer. Audio must modulate *forces / parameters*, never `p` directly.
5. **Spawning at the attractor** → particles pile up at the bright centre.
   Spawn on a wide ring; the attractor is something they *arrive at*.
6. **Trail fade too aggressive (≤0.85)** → no trails. Too gentle (≥0.99) →
   screen turns into a smear. Stay in `0.92..0.97`.
7. **Non-divergence-free field** (e.g. plain Perlin gradient) → particles
   converge to noise minima and the cloud collapses. Use curl(ψ).
8. **Calling `curl` with `time` *added inside* the noise call but at the same
   rate as spatial coords** → noise frequency dominates time, field looks
   frozen. Time should advance slower than space (factor ~0.15).
9. **Premultiplied vs straight alpha confusion under additive blending** →
   output goes pink/grey. With additive `(srcAlpha, one)`, ensure fragment
   outputs `(col*a, a)`, not `(col, a)`.
10. **IO-thread audio dispatched on wrong queue** → spectrum is stale, the
    scene "feels laggy". (This repo's IOProc is on Core Audio's IO thread; see
    `CoreAudioTapCapture.swift`.) Not a particle issue but commonly mis-blamed.
11. **`hash21` on the same `(seed, t)` every frame** → particles flicker. Use
    `hash21(seed, floor(t * spawnRate))` so the value is stable within a spawn.

## Comparison with current implementation

Read of `AlchemyScene.swift` + `AlchemyParticles.metal`:

| Concern | Current | Canonical | Gap |
|---|---|---|---|
| Particle count | 120k | 120k | OK |
| Noise type | 2D value noise, single octave | fBm 3-octave value/simplex | shallow field, lacks low-freq sweep |
| Curl formula | `(n1-n2, -(n3-n4))` over y/x | same, but stream-function form is identical | OK; ε=0.08, fine |
| Time-evolution | added to spatial coord (`p + (t*0.15, 0)`) | use separate noise-z slice | the additive shift only translates the field, doesn't morph it |
| Drag | `mix(0.985, 0.93, beat)` — beats *increase* drag | should be `mix(0.985, 0.92, bass)`; beats are impulses, not damping | inverted: beats should *unleash* energy, not damp it |
| Velocity cap | none | `vmax = 2.5` | runaway risk |
| Beat impulse | `radial * beat * 0.6 * dt * sin(seed*31.4)` | radial impulse independent of `dt`, signed by `sign(dot(v, radial))` or just outward | `*dt` shrinks the kick at high FPS; should be a per-frame impulse |
| Bass coupling | strong (force, tangent both scaled by bass) | OK | keep |
| Mid coupling | swirl strength only | curl frequency AND swirl | mid currently does not change *what the field looks like* |
| Treble coupling | only shortens life | spawn sparkle particles + hue jitter | missing the "high-end sparkle" signature |
| Trails | none — additive sprites on cleared FB | ping-pong feedback with 0.94 fade | this is the single biggest missing piece for "alive" |
| Color | palette by hue=f(angle, life, bass) | IQ cosine palette modulated by beat phase | current is OK but flat across the scene |
| Bloom | none | tiny 4-tap box blur on output | optional, big visual lift |
| Spawn shape | ring around Lissajous attractor | same | OK |
| Sprite shape | Gaussian core + halo | same | OK |
| Sparkle pool | none | 8k separate kind=1 particles | missing |
| Frame-rate independence | drag is `*0.985` per frame (60-Hz tuned) | `pow(0.985^60, dt)` = exact | minor at 60 Hz, audible at 120 Hz |

## Concrete fix list

1. **Add a feedback/trail pass.** Allocate two BGRA8Unorm_sRGB textures
   matching the drawable. Each frame: fade-blit B→A with `multiply = 0.945 -
   0.020*beat`, draw particles additively into A, blit A to drawable. Biggest
   single visual win.
2. **Replace single-octave value noise with 3-octave fBm.** Weights `(1.0,
   0.5, 0.25)`, lacunarity 2. Adds a low-frequency sweep that makes the field
   feel like fluid instead of fog.
3. **Make noise time-evolve via a 3rd coordinate**, not by translating the 2D
   domain. Pass `t * 0.15` as `z` into a 3D noise.
4. **Invert beat→drag coupling.** Currently `mix(0.985, 0.93, beat)` *damps*
   on beat. Change to `drag = mix(0.985, 0.92, bass)` (so bass loosens the
   cloud) and leave the beat impulse to do the punctuation.
5. **Remove `* dt` from the beat impulse term.** It's an instantaneous
   per-frame velocity kick; `dt` makes it depend on frame rate. Apply
   `v += radial * 0.9 * beat * sign(...)` once per beat-positive frame.
6. **Cap velocity** at `vmax = 2.5` after integration.
7. **Convert drag to per-second form:** `v *= pow(dragPerSec, dt)`. Tiny code
   change, removes a frame-rate dependency.
8. **Couple `mid` to curl scale**, not just swirl: `q = pos * (1.4 + 1.6*mid)
   + seed*7.3`. Now mids visibly change the *texture* of the swirl.
9. **Add a sparkle particle pool** (`kind = 1`, lifetime 0.15–0.40 s, spawn
   rate `200 + 6000*treble`/s). Render with smaller, whiter sprites
   (`palette(t) * 1.4 + vec3(0.2)` clamped). Treble currently has almost no
   visual signature.
10. **Switch palette to IQ cosine** with a `paletteOffset` that nudges by
    `+0.05 * beat` per beat — gives the screen a visible color flash on
    drops without recomputing a texture.
11. **Add a 4-tap separable box blur** (radius 1.5 px) on the feedback texture
    before fade-multiply. Cheap glow; reads as "bloom" at no real cost.
12. **Use bands 0–7, 8–31, 32–63 explicitly** for bass/mid/treble (the code
    currently splits at `bandCount/4` and `bandCount*3/4` which works for 64
    bands but breaks if the band count ever changes). Hard-code or expose.

## References

1. Bridson, Houriham, Nordenstam. *Curl-noise for procedural fluid flow*.
   SIGGRAPH 2007. https://www.cs.ubc.ca/~rbridson/docs/bridson-siggraph2007-curlnoise.pdf
2. Dziewanowski, E. *Dissecting Curl Noise*. https://emildziewanowski.com/curl-noise/
3. Dziewanowski, E. *Flowfields*. https://emildziewanowski.com/flowfields/
4. Codrops. *Creating Audio-Reactive Visuals with Dynamic Particles in
   Three.js*. https://tympanus.net/codrops/2023/12/19/creating-audio-reactive-visuals-with-dynamic-particles-in-three-js/
5. Quilez, I. *Palettes*. https://iquilezles.org/articles/palettes/
6. Atyuwen. *Fast Divergence-Free Noise (bitangent noise)*. https://atyuwen.github.io/posts/bitangent-noise/
7. Moroz, M. *Overview of Shadertoy particle algorithms*. https://michaelmoroz.github.io/TODO/2021-3-13-Overview-of-Shadertoy-particle-algorithms/
8. Winamp Wiki. *Visual Developer — Superscope, Dynamic Movement*. http://wiki.winamp.com/index.php?title=Visual_Developer
