# Canonical Kaleidoscope

## Visual goal

A slowly drifting, hypnotic **mandala**: a deep procedural pattern (noise field
or polar-warped texture) viewed through an **N-fold rotational + mirror
symmetry** so every slice is a reflection of its neighbour. Colours cycle
through a smooth perceptual palette; bass squeezes the centre outward, mids
modulate the rotation, treble sparkles around the rim, and beats briefly
double the segment count and flash the whole image. The defining feeling is
**continuous, organic motion under hard rotational symmetry** — never a frozen
mandala, never a generic polar warp.

References:

- Iñigo Quilez, *Procedural Color Palettes* —
  https://iquilezles.org/articles/palettes/
- Daniel Ilett, *Crazy Kaleidoscopes (Ultra Effects pt. 8)* —
  https://danielilett.com/2020-02-19-tut3-8-crazy-kaleidoscopes/
- Shadertoy `tfdXRS` ("kaleidoscope shader") and `ldsXWn`
  ("Kaleidoscope Visualizer") — canonical fold-and-sample reference
  implementations.

## Inputs

Per frame the scene receives:

- `spectrum.bands: [Float]` — 64 linear-frequency FFT magnitudes in ~[0, 1].
- `waveform: [Float]` — 1024 PCM in [-1, 1] (unused; mandala does not need
  per-sample data).
- `beat: BeatEvent?` — optional, with `strength ∈ [0, 1]`.
- `dt: Float` — frame interval in seconds.
- Uniforms: `time, aspect, rms, beatStrength`.

Band aggregation (computed CPU-side before the draw):

```
bass   = mean( bands[0  .. 6 ) )    // 0–2.25 kHz
mid    = mean( bands[6  .. 24) )    // 2.25–9 kHz
treble = mean( bands[24 .. 56) )    // 9–21 kHz
```

These three scalars, smoothed with one-pole IIRs at different time constants
(see the constants table), drive every audio-reactive parameter in the shader.

## Algorithm — step by step

### 1. Normalised, aspect-corrected pixel coordinate

```
uv  = ndc                                  // [-1, 1]² from the fullscreen quad
uv.x *= aspect                             // pre-aspect-correct so the
                                           // pattern is round, not oval
```

### 2. Convert to polar, then **fold** into one wedge

This is the canonical n-fold mirror trick. With `N` segments
(`N ∈ {6, 8, 10, 12}`):

```
r       = length(uv)
θ       = atan2(uv.y, uv.x) + rotate       // pre-rotated angle
slice   = π / N                            // half-wedge width
                                           // (full wedge = 2π/N = 2·slice)
θwrap   = mod( θ + π, 2·slice )            // wrap into [0, 2·slice)
θfold   = abs( θwrap - slice )             // mirror around slice centre
                                           //   → θfold ∈ [0, slice]
```

`θfold ∈ [0, π/N]` is the folded angle. Two equivalent ways to express the
same fold are:

```
// One-liner (Iñigo / Daniel Ilett form):
θfold = abs( mod(θ + slice, 2·slice) - slice );

// Or, identical, using floor:
θfold = θ - 2·slice · floor( (θ + slice) / (2·slice) );  θfold = abs(θfold);
```

Reconstruct a Cartesian sample coordinate in the folded space:

```
p = r · vec2( cos(θfold), sin(θfold) )
```

**This is the load-bearing line of the whole effect.** Sampling the pattern at
`p` (the folded coord) instead of at `uv` (the unfolded coord) is what gives
the kaleidoscope its mirror symmetry. Any pattern function `pattern(p)`
automatically inherits 2N-fold dihedral symmetry (N rotations × mirror).

### 3. Source pattern in folded space

The folded coord `p` is fed into a 2D pattern. Two interchangeable canonical
choices:

**(a) Domain-warped value-noise FBM** (preferred — feels organic):

```
q = p · freq                                       // freq ≈ 2.0
q = q + 0.5 · vec2( fbm(q + time·0.07),
                    fbm(q + 7.7 + time·0.05) )    // domain warp
f = fbm( q + time·0.10 )                           // ∈ ~[0, 1]
```

`fbm` is 4-octave value noise with `lacunarity = 2.0`, `gain = 0.5`.

**(b) Layered ring/spoke pattern** (cheaper, more "stained glass"):

```
rings = 0.5 + 0.5 · sin( r · (10 + bass·6) - time·1.3 )
spokes= 0.5 + 0.5 · sin( θfold · (2·N) + time·0.9 )
f     = mix( rings, spokes, 0.5 + 0.5·sin(time·0.4) )
```

Either way `f ∈ ~[0, 1]` is the scalar that drives colour.

### 4. Hue cycling via cosine palette (Iñigo Quilez)

```
col(t) = a + b · cos( 2π · (c·t + d) )

t = f + time · 0.05 + bass · 0.10

// Iridescent / mandala-friendly default constants:
a = vec3(0.50, 0.50, 0.50)
b = vec3(0.50, 0.50, 0.50)
c = vec3(1.00, 1.00, 1.00)
d = vec3(0.00, 0.33, 0.67)        // 120° RGB phase offsets
```

`c` must be integer-or-half so the palette loops over `t ∈ [0, 1]`.

### 5. Audio coupling

| Audio band  | Smoothing τ | Drives                                | Math                                                  |
|-------------|-------------|---------------------------------------|-------------------------------------------------------|
| bass        | 120 ms      | radial zoom into pattern, palette `t` | `freq = freqBase · (1 + bass·0.8)`; `t += bass·0.10` |
| mid         | 200 ms      | rotation speed                        | `rotate += dt · (rotBase + mid·1.2)` (CPU-side)      |
| treble      | 60 ms       | high-freq grain / sparkle layer       | `f += treble · 0.15 · grainNoise(p·30 + time·8)`     |
| beatStrength| 80 ms       | flash + temporary 2N segments         | see step 6                                            |
| rms         | 250 ms      | overall brightness                    | `col *= 1 + rms·0.20`                                |

### 6. Beat-driven N-doubling and flash

Beats inject a brief impulse `b ∈ [0, 1]` (raw `beat.strength`) that decays at
80 ms. Use it for **two** simultaneous effects:

```
// Effective segments — bump to 2N for ~100 ms after a beat:
Neff = N + N · step(0.5, beatEnvelope)         // hard switch above 0.5
// (equivalently: if beatEnvelope > 0.5 use 2N, else N)

// Brightness flash:
col += beatEnvelope · 0.18 · vec3(1.0)
```

Doubling N (not blending it) avoids the strobing artefact that happens when N
is fractional — the fold formula requires integer N or you get visible seams
where the wedge boundaries no longer meet themselves.

### 7. Continuous rotation

Updated CPU-side once per frame and passed in as a single scalar uniform:

```
rotate += dt · (rotBase + mid · 1.2)        // rotBase = 0.10 rad/s
```

Never reset `rotate` to zero between frames — the slow continuous drift is
the second most important property of the effect after the fold itself.

### 8. Centre-hole softening

The polar origin (`r = 0`) is a coordinate singularity: noise is undefined
there and ring patterns pile up to a point. Fade to either black or the mean
pattern colour inside a small disc:

```
centerMask = smoothstep( 0.04, 0.10, r )        // 0 at centre, 1 outside
col       *= centerMask
```

Optionally add a soft white-hot core that pulses with bass:

```
core   = (1 - centerMask) · (0.6 + 0.8 · bass)
col   += core · vec3(1.0, 0.95, 0.85)
```

### 9. Outer vignette (optional but canonical)

Mandala compositions traditionally fade to black at the edge so the symmetry
"floats". A cheap radial vignette:

```
col *= smoothstep( 1.10, 0.35, r )
```

## Critical numerical constants

| Symbol        | Value          | Meaning                                                |
|---------------|----------------|--------------------------------------------------------|
| `N`           | 8 (∈ {6,8,10,12}) | Segment count. Even integer, picked at `randomize()`. |
| `slice`       | `π / N`        | Half-wedge width                                        |
| `freqBase`    | 2.0            | Spatial frequency of the noise field                    |
| `octaves`     | 4              | FBM octaves                                             |
| `lacunarity`  | 2.0            | FBM frequency multiplier per octave                     |
| `gain`        | 0.5            | FBM amplitude multiplier per octave                     |
| `warpAmp`     | 0.5            | Domain-warp strength                                    |
| `warpSpd`     | 0.07           | Domain-warp time scrolling rate                         |
| `huePalette`  | a=b=(.5,.5,.5), c=(1,1,1), d=(0,.33,.67) | Iridescent cosine palette       |
| `hueDrift`    | 0.05           | Palette `t` time scrolling rate                         |
| `rotBase`     | 0.10 rad/s     | Base rotation rate (always on)                          |
| `rotMidGain`  | 1.20           | Extra rotation per unit mid                             |
| `bassZoom`    | 0.80           | Bass → noise frequency multiplier                       |
| `trebleGrain` | 0.15           | Treble → grain amplitude                                |
| `bassTauMs`   | 120            | Bass IIR time constant                                  |
| `midTauMs`    | 200            | Mid IIR time constant                                   |
| `trebleTauMs` | 60             | Treble IIR time constant                                |
| `beatTauMs`   | 80             | Beat envelope time constant                             |
| `flashAmp`    | 0.18           | Peak beat brightness boost                              |
| `nDoubleThr`  | 0.50           | Beat envelope above this → use 2N segments              |
| `coreR0`      | 0.04           | Inner radius of centre fade                             |
| `coreR1`      | 0.10           | Outer radius of centre fade                             |
| `vignR0`      | 1.10           | Vignette outer (full dark) radius                       |
| `vignR1`      | 0.35           | Vignette inner (full bright) radius                     |

## Common pitfalls

1. **Forgetting the fold.** Doing `θ + rotate` then sampling at
   `r·(cosθ, sinθ)` is a polar warp, not a kaleidoscope — there is no mirror
   line and no rotational symmetry beyond what the source pattern already
   has. The defining step is `θfold = abs(mod(θ+slice, 2·slice) - slice)`.

2. **Half-mirror instead of full fold.** `θ = mod(θ, 2·slice)` alone gives N
   rotated copies but **no mirror** — adjacent wedges look discontinuous at
   the boundary. The `abs(... - slice)` mirrors each wedge against its
   neighbour, which is what makes the seams invisible.

3. **Static N and static pattern.** A motionless mandala is a screensaver.
   Need at least: continuous `rotate` drift, time-scrolled noise field, and
   palette cycling. Audio modulation is then layered on top.

4. **Fractional N.** Smoothly lerping N between integers produces a visible
   seam that sweeps around the figure. If you want to "morph" symmetry,
   either snap N or cross-fade two complete renders with different N.

5. **No centre hole.** Value/simplex noise is mathematically well-defined at
   the origin, but the visual is dominated by a single high-amplitude
   speckle that becomes a strobing dot. Fade with `smoothstep`.

6. **Sampling the unfolded `uv` in the pattern.** Easy regression: passing
   `uv` instead of `p` into `pattern(...)` silently breaks the symmetry.
   The fold output `p = r·(cos θfold, sin θfold)` must be the only thing
   that reaches the noise/texture lookup.

7. **No mirror at wedge centre.** If `θfold = mod(θ+slice, 2·slice)` (no
   `abs`), seams appear at half the angular frequency.

8. **Beat strobing on N.** Continuously remapping N to a beat envelope
   strobes the wedge count. Use a hard `step(0.5, env)` so N is integer at
   every instant and only changes once per beat.

9. **`fmod` of a negative number.** In Metal, `fmod(-0.3, 1.0) = -0.3`, not
   `0.7`. Always add `2π` (or another full period) before `fmod`/`mod` on
   the angle.

10. **Aspect-correcting after the fold.** Multiplying `uv.x *= aspect` must
    happen **before** polar conversion, or the mandala squishes into an oval.

## Comparison with current implementation

Reading `Sources/Domain/.../SceneUniforms`, `KaleidoscopeScene.swift`, and
`Kaleidoscope.metal`:

| Aspect                        | Current                                                | Canonical                                                  | Gap        |
|-------------------------------|--------------------------------------------------------|------------------------------------------------------------|------------|
| Aspect correction             | `p.x *= aspect` before polar                           | Same                                                       | OK         |
| Angle wrap                    | `fmod(a + TWO_PI, wedge)`                              | `mod(θ + π, 2·slice)`                                      | OK         |
| Mirror across wedge centre    | `if (a > wedge*0.5) a = wedge - a`                     | `abs(θwrap - slice)`                                       | Equivalent |
| Pattern in folded space       | `sin(r·…) + sin(a·18)` mix                             | Domain-warped value-noise FBM                              | **Thin**   |
| Hue cycling                   | 1-D palette texture `palette.sample(palU,.5)`          | Cosine palette with time + bass drift                      | Different — palette texture is fine; needs explicit time/audio coupling on `palU` |
| Bass coupling                 | Only `rings` frequency `(10 + bass·6)`                 | Bass → freqBase, palette `t`, central core                 | Partial    |
| Mid coupling                  | None                                                   | Mid → rotation rate                                        | **Missing**|
| Treble coupling               | None                                                   | Treble → grain / sparkle                                   | **Missing**|
| Beat coupling                 | None                                                   | Flash + N-doubling for 100 ms                              | **Missing**|
| Continuous rotation           | `u.spin + u.time · 0.06` inside shader                 | `rotate` integrated on CPU at `rotBase + mid·1.2`          | Weak — rotation rate is fixed and unconnected to audio |
| Centre softening              | `exp(-r·1.4)` brightness, no hard mask                 | `smoothstep(0.04, 0.10, r)` plus optional hot core          | Different shape; current is just "brighter centre", not a hole |
| Outer vignette                | None                                                   | `smoothstep(1.10, 0.35, r)`                                | Optional, missing |
| FBM / domain warp             | None                                                   | 4-octave value-noise FBM with warp                          | **Missing**|
| Per-band smoothed inputs      | Only `bass` IIR (`τ ≈ dt/0.12`, frame-rate dependent) | `bass`, `mid`, `treble`, `beat` IIRs with explicit τ in ms  | **Missing**|

## Concrete fix list

1. **`KaleidoscopeScene.swift` — extend the smoothed inputs.** Add `mid`,
   `treble`, `beatEnv`, and a CPU-integrated `rotate` scalar to the struct.
   Replace the current frame-rate-dependent `bass += (target - bass) * 0.12`
   with `dt`-aware IIRs: `bass += (target - bass) * (1 - exp(-dt/0.120))`
   for each band, with τ from the constants table.

2. **`KaleidoscopeScene.swift` — band slicing.** Compute
   `bass = mean(bands[0..<6])`, `mid = mean(bands[6..<24])`,
   `treble = mean(bands[24..<56])` each frame before smoothing.

3. **`KaleidoscopeScene.swift` — beat handling.** On `beat != nil`, set
   `beatEnv = max(beatEnv, beat.strength)`. Each frame decay
   `beatEnv *= exp(-dt / 0.080)`.

4. **`KaleidoscopeScene.swift` — rotation.** Replace fixed `spin` with a
   per-frame integrator: `rotate += dt * (0.10 + mid * 1.2)`. Keep `rotate`
   wrapped to `[0, 2π)` to avoid float blowup over long sessions.

5. **`KaleidoscopeScene.swift` — uniforms struct.** Expand `KUniforms` to:
   `aspect, time, rms, bass, mid, treble, beatEnv, rotate, sectors`.
   Drop the standalone `spin` (folded into `rotate`).

6. **`Kaleidoscope.metal` — add value-noise FBM helpers.** Implement
   `float hash21(float2)`, `float vnoise(float2)`, `float fbm(float2)`
   (4 octaves, lacunarity 2.0, gain 0.5). These are small and well-known
   (Iñigo Quilez snippet).

7. **`Kaleidoscope.metal` — replace the pattern body** with a domain-warped
   FBM in the folded coord `p`:
   ```
   float freq = 2.0 * (1.0 + u.bass * 0.8);
   float2 q = p * freq;
   q += 0.5 * float2(fbm(q + u.time*0.07),
                     fbm(q + 7.7 + u.time*0.05));
   float f = fbm(q + u.time*0.10);
   f += u.treble * 0.15 * (hash21(p*30 + u.time*8) - 0.5);
   ```

8. **`Kaleidoscope.metal` — fold formula.** Replace the if-branch with the
   branchless canonical form:
   ```
   float slice = M_PI_F / float(N);
   float th    = atan2(p.y, p.x) + u.rotate;
   float th2   = fmod(th + slice + 6.28318530718, 2.0 * slice);
   float thF   = fabs(th2 - slice);
   float2 fp   = r * float2(cos(thF), sin(thF));
   ```
   Note `+ 6.28318530718` (one full period) before `fmod` to handle negative
   angles, since Metal's `fmod` preserves sign.

9. **`Kaleidoscope.metal` — N-doubling on beat.** Compute
   `int N = u.sectors * (1 + int(step(0.5, u.beatEnv)))`.

10. **`Kaleidoscope.metal` — palette and flash.** Use the palette texture if
    keeping the existing 1-D ramp, but drive `palU` with the noise field
    plus time/bass:
    ```
    float palU = fract(f + u.time*0.05 + u.bass*0.10);
    float3 col = palette.sample(s, float2(palU, 0.5)).rgb;
    col *= 1.0 + u.rms * 0.20;
    col += u.beatEnv * 0.18;
    ```

11. **`Kaleidoscope.metal` — centre and vignette.**
    ```
    float centerMask = smoothstep(0.04, 0.10, r);
    col *= centerMask;
    col *= smoothstep(1.10, 0.35, r);
    ```
    Add the hot-core contribution if desired:
    `col += (1.0 - centerMask) * (0.6 + 0.8 * u.bass) * float3(1.0, 0.95, 0.85);`

12. **`KaleidoscopeScene.swift::randomize()` — keep N stable.** Already only
    picks `{6, 8, 10, 12}` (good). Do **not** add fractional or runtime-
    varied N — N changes only at scene shuffle. Beat-doubling is the sole
    runtime exception and uses a hard `step`, not a lerp.

## References

1. Iñigo Quilez, *Procedural Color Palettes* —
   https://iquilezles.org/articles/palettes/
2. Iñigo Quilez, *Domain Warping* —
   https://iquilezles.org/articles/warp/
3. Daniel Ilett, *Ultra Effects pt. 8 — Crazy Kaleidoscopes* (exact fold
   code) — https://danielilett.com/2020-02-19-tut3-8-crazy-kaleidoscopes/
4. Shadertoy, *kaleidoscope shader* (`tfdXRS`) —
   https://www.shadertoy.com/view/tfdXRS
5. Shadertoy, *Kaleidoscope Visualizer* (`ldsXWn`, audio-reactive) —
   https://www.shadertoy.com/view/ldsXWn
6. Shadertoy, *Polar coordinates tutorial* (`Wtf3RH`) —
   https://www.shadertoy.com/view/Wtf3RH
7. The Book of Shaders, ch. 13 — *Fractal Brownian Motion* —
   https://thebookofshaders.com/13/
8. Advanced Visualization Studio (Winamp AVS), Mirror trans module —
   https://github.com/grandchild/vis_avs/
