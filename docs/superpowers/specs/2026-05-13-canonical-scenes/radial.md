# Radial spectrum — canonical design

## Visual goal

A **circular log-frequency spectrum** that reads as a glowing wheel of energy: bass at the top, treble curling around to either side, mirrored across the vertical axis so the figure is left/right symmetric (like a music-video poster). Bars stand on a thin pulsing inner ring, are colored by a rainbow palette that rotates slowly with time, and brighten on beat. The whole thing should feel like a *clock face of frequency*, not a noisy chart — it has to look composed when paused, not just "FFT in a polar projection."

References:
- audioMotion-analyzer "radial" mode — bars spread radially from the center, rotating clockwise at a configurable RPM, with an inner radius parameter. ([audioMotion-analyzer README](https://github.com/hvianna/audioMotion-analyzer))
- After Effects "Audio Spectrum" effect with **Circle** path option + **Polar Warp** — the canonical YouTube music-video look. ([Radial Audio Spectrum Tutorial](https://www.youtube.com/watch?v=YLwi97erH1U))
- Shadertoy / GLava radial modules — full-screen fragment-shader implementation, SDF-based wedges, polar coordinates from `atan2`. ([GLava](https://github.com/jarcode-foss/glava))

## Inputs

Per-frame data:

| Input | Type | Range | Notes |
|---|---|---|---|
| `spectrum.bands` | `[Float]` (64) | `[0, 1]` linear magnitude | Already normalized, linear-frequency |
| `waveform` | `[Float]` (1024) | `[-1, 1]` PCM | Used by optional center mini-scope |
| `beat` | `BeatEvent?` | nil or `(strength, time)` | Drives ring pulse + rotation kick |
| `dt` | `Float` | seconds | Frame delta for envelopes |

Scene uniforms: `time, aspect, rms, beatStrength`.

## Algorithm

### Step 1 — Log-frequency remap (64 linear → N=128 log bands)

Linear FFT bands clump treble into ~3/4 of the circle. Remap to constant-Q log bands so each "octave" gets equal angular real estate.

For each output band `j ∈ [0, N)`, compute its center frequency on a log scale spanning `f_lo = 40 Hz` to `f_hi = 16000 Hz`:

```
t      = (j + 0.5) / N
f_j    = f_lo * pow(f_hi / f_lo, t)            // log-spaced center
binF   = f_j / (sampleRate / fftSize)           // fractional input bin
i_lin  = binF * 64 / (fftSize/2)                // map into 64-band array
```

Sample `spectrum.bands` with **linear interpolation** between `floor(i_lin)` and `ceil(i_lin)`. For bands wider than one input bin (the high end), take the **max** over the covered bins so transients don't get averaged into silence.

Then apply log-magnitude compression so quiet bands don't hug the floor:

```
mag_j = log10(1 + 9 * raw_j) / log10(10)        // identity at 0 and 1, lifted in middle
```

### Step 2 — Mirrored layout

The figure is mirrored across the **vertical axis** so it reads as symmetric. Render only `N/2 = 64` log bands across angles `θ ∈ [-π/2, +π/2]` on the **right half**, then mirror to the left half by reflecting `θ → -θ` in the shader (`p.x = |p.x|` before the angle math).

This doubles visual density without doubling band count and gives the figure a designed feel.

### Step 3 — Angle mapping

Lowest band (bass) at the **top** (12 o'clock), highest band at the bottom (6 o'clock), wrapping clockwise on the right:

```
N_half = N / 2 = 64
θ_j    = -π/2 + π * (j + 0.5) / N_half          // j ∈ [0, 64), θ ∈ (-π/2, +π/2)
```

After the `p.x = |p.x|` mirror, both halves of screen-space hit `θ ∈ [0, π]`. In the shader, reflect again so that angle 0 maps to the top:

```glsl
float a = atan2(|p.x|, -p.y);                   // 0 at top, π at bottom
int   j = clamp(int(a / π * N_half), 0, N_half-1);
```

### Step 4 — Inner / outer radius

Anchor to the **shorter screen dimension** (square-feeling figure on any aspect):

```
minDim   = min(1.0, aspect)                     // ndc with aspect-corrected p.x
r_inner  = 0.25                                 // fraction of minDim
r_max    = 0.85                                 // outer envelope cap
barLen_j = (r_max - r_inner) * mag_j            // 0..0.60
r_outer_j= r_inner + barLen_j
```

### Step 5 — Angular bar width

Each band gets a wedge with a small gap so adjacent bars don't bleed together:

```
δθ      = π / N_half                            // total slice = 180° / 64 = 2.8125°
gap     = 0.18 * δθ                             // 18% gap
half_w  = δθ * 0.5 - gap * 0.5                  // half angular width
```

### Step 6 — Anti-aliased polar bar (SDF wedge)

Each bar is the intersection of an **angular wedge** and a **radial annulus**. AA both edges using `fwidth`:

```glsl
// Distance in radians from bar center angle:
float aDist = abs(a - θ_j);
float aaA   = fwidth(aDist) + 1e-4;
float ang   = 1.0 - smoothstep(half_w - aaA, half_w + aaA, aDist);

// Radial mask:
float aaR   = fwidth(dist) + 1e-4;
float inner = smoothstep(r_inner - aaR, r_inner + aaR, dist);
float outer = 1.0 - smoothstep(r_outer_j - aaR, r_outer_j + aaR, dist);

float bar   = ang * inner * outer;
```

This is the iquilezles "pie SDF" pattern adapted for an annular wedge — gives crisp tips at high band magnitudes and clean edges at glancing angles. ([2D SDFs](https://iquilezles.org/articles/distfunctions2d/))

### Step 7 — Beat ring

A thin ring at `r_inner` is always present at low intensity. On beat, it pulses outward and brightens:

```
ringR    = r_inner + 0.04 * beatStrength
ringHalf = 0.006 + 0.010 * beatStrength
ring     = exp(-pow((dist - ringR) / ringHalf, 2.0))
ringCol  = mix(white, palette(0.5), 0.4) * ring * (0.4 + beatStrength)
```

The ring is **independent** of the angular mask — it goes all the way around — so beats read as a global breath, not as more bars.

### Step 8 — Center waveform mini-scope (optional, on by default)

Inside `r < r_inner * 0.85`, plot the time-domain waveform as a **closed polar curve**:

```
for k in 0..512:                      // half of 1024-sample waveform
  φ_k     = 2π * k / 512
  amp_k   = waveform[k * 2]           // every other sample
  r_k     = 0.5 * r_inner * (1 + 0.6 * amp_k)
  // emit polyline / triangle strip
```

Render as a 2-pixel-wide additive line (build a triangle strip CPU-side, push to a small vertex buffer). Alternatively, in fragment-shader-only mode, sample the waveform from a 1D texture and compute `r_target` for the current `φ`, draw with `smoothstep(0, fwidth, abs(dist - r_target))`.

### Step 9 — Color

Palette sampled by `(j / N_half)` along the rainbow texture, mixed with magnitude-driven brightness:

```
float palU = float(j) / float(N_half);          // 0 at top → 1 at bottom
float3 hue = palette.sample(s, float2(palU, 0.5)).rgb;
float3 col = hue * (0.45 + 0.55 * mag_j);       // dimmer bars stay readable
```

For mirrored symmetry the **right and left halves share the same `j`** — both legs of the wheel are the same color at the same angular position. This is what makes it look intentional rather than chaotic.

### Step 10 — Rotation

```
rot_base = time * 0.05                          // slow, hypnotic
rot_kick = 0.15 * beatDecay                     // beatDecay = exp(-2*timeSinceBeat)
rot      = rot_base + rot_kick
```

Apply the rotation as `a = a - rot` *before* the band index lookup — bands spin together as a rigid wheel. The mirror axis stays fixed at the vertical, so the figure rotates but remains symmetric.

## Critical numerical constants

| Constant | Value | Why |
|---|---|---|
| `N` (total log bands) | 128 | Visual density target |
| `N_half` (rendered bands) | 64 | Mirror axis halves the work |
| `f_lo` | 40 Hz | Below this is mostly room rumble |
| `f_hi` | 16 kHz | Above this air-band is sparse |
| `r_inner` | 0.25 | Leaves room for center scope |
| `r_max` | 0.85 | Don't kiss the screen edge |
| `gapFrac` | 0.18 | Visible gap, not gappy |
| `rotSpeed` | 0.05 rad/s | ~3°/s — felt but not dizzy |
| `beatRotKick` | 0.15 rad | Half a band-slice — noticeable |
| `riseEnv` | 0.55 (per-frame lerp) | Snappy attack |
| `fallEnv` | `1 - exp(-4dt)` | Slow decay, ~250 ms |
| `logMagK` | 9 in `log10(1+9x)` | Lifts -20 dB to 0.5 |

## Common pitfalls

1. **Linear frequency mapping** — 64 linear bins → ~90% of the circle is mid/treble noise and the bass kick lives in 2 bars. Log remap is non-negotiable.
2. **No log magnitude** — bars hug the inner ring on every track because peak energy is in 2–3 bins. Apply `log10(1 + 9x)` (or dB with floor at -60).
3. **No AA on angular edges** — `floor(a / slice)` jumps one bar to the next per pixel, producing jaggies that twinkle as the figure rotates. Always smoothstep both edges with `fwidth`.
4. **Aspect-broken circle** — forgetting to multiply `p.x` by `aspect` makes the wheel into an ellipse on widescreen.
5. **Mirror artifact at the seam** — if you mirror by `p.x = abs(p.x)` *after* computing `atan2`, the top/bottom bands appear half-width. Mirror *before* the angle calc.
6. **Rotation jitter from `fmod`** — `fmod(angle, 2π)` after `atan2` can flip sign across the discontinuity. Use the `atan2(|x|, -y)` form which is single-valued on `[0, π]`.
7. **Beat ring stealing the bars** — if the ring is multiplied by the angular mask, it appears only where bars are. Apply the ring as a separate additive layer.
8. **Center scope clipping the wheel** — if `r_inner < amplitude`, the scope spills under the bars; clamp scope radius to `r_inner * 0.85`.

## Comparison with current implementation

Current files: [`RadialScene.swift`](../../../../AudioVisualizer/Infrastructure/Metal/Scenes/RadialScene.swift), [`Radial.metal`](../../../../AudioVisualizer/Infrastructure/Metal/Shaders/Radial.metal).

What it does today:
- Full 360° wrap, no mirror — `bar = floor(a / slice)` over `[0, 2π)`.
- Linear frequency: directly indexes `spectrum.bands[bar]`. No log-frequency remap.
- No log-magnitude compression: `displayed[i] += (target - displayed[i]) * rise/fall`.
- AA both radial and angular edges via `fwidth` + `smoothstep`. (Good.)
- Inner ring "core" via `exp(-|d - innerR| * 22) * 0.5` — present, but **doesn't react to beats** (no `beatStrength` uniform).
- Outer glow via `exp(-|d - outerR| * 14) * 0.45 * angMask`. (Good — keep.)
- No center waveform scope.
- Slow rotation `time * 0.08`. No beat-kick rotation.
- Palette sampled by **radial distance** (`(dist - innerR) / maxBarH`), so all bars share the same color gradient and there's no "rainbow around the wheel" effect.
- `barCount` randomized in `[24, 32, 48, 64, 80, 96]` — but the input array is only 64 bands, so for `barCount > 64` the code wraps `i % n` which duplicates bass bands at the bottom of the wheel. Looks weird.
- No `beatStrength` ever reaches the shader — `SceneUniforms` is consulted in `encode` but only `aspect, time, barCount, rms` go to GPU.

Gaps vs. canonical:
- (a) Linear band mapping → bass under-represented.
- (b) No magnitude compression → bars flicker at the base.
- (c) Full circle vs. mirrored → no left/right symmetry.
- (d) Radial palette vs. angular palette → no rainbow ring.
- (e) No beat reactivity in shader.
- (f) No center scope.
- (g) Band duplication wraps when barCount > 64.

## Concrete fix list

1. **Add a log-frequency remap on the CPU side.** Precompute `logBandTable[N_half]` of `(lowBin, highBin, fracLo, fracHi)` at scene build (depends only on `sampleRate` and `fftSize`). In `update`, fill `displayed[N_half]` by accumulating `max()` of `spectrum.bands` over each log band's bin range, with edge-bin weighting.
2. **Apply log-magnitude compression** inside `update`: `target = log10(1 + 9 * raw) / 1.0` before the rise/fall envelope.
3. **Reduce `barCount` to a fixed 64** (the rendered half). Drop the random `[24..96]` set — the visual density target is now constant. Randomize *rotation direction* and *mirror on/off* instead.
4. **Add `beatStrength` and `beatPhase` to `RadialUniforms`.** Wire them in `CompositionRoot` and pass through `SceneUniforms` into `encode`.
5. **Mirror in the shader before the angle math:** `float2 q = float2(abs(p.x), p.y); float a = atan2(q.x, -q.y);` — angle 0 at top, increasing to π at bottom.
6. **Use angular palette sampling:** `palU = a / π` so the rainbow wraps from bass (top) to treble (bottom), same on both halves of the screen.
7. **Add the beat ring as a separate additive layer**, *not* gated by the angular mask. Drive both its radius and brightness by `beatStrength`.
8. **Add a slow rotation `time * 0.05` plus a beat-kick** `0.15 * exp(-2 * timeSinceBeat)`. Apply before the band-index lookup.
9. **Add a center waveform mini-scope.** Either (a) build a separate pipeline with a small dynamic vertex buffer for a closed polar polyline, or (b) extend `Radial.metal` to sample a 1D `waveform` texture and draw it via fragment AA inside `dist < 0.85 * r_inner`.
10. **Tighten visual constants** to the table above: `r_inner = 0.25`, `r_max = 0.85`, `gapFrac = 0.18`, `rotSpeed = 0.05`. Lift glow/core constants only after the geometry above is correct so beat reactivity reads.

## References

- [audioMotion-analyzer (README, radial mode)](https://github.com/hvianna/audioMotion-analyzer)
- [audioMotion live demo](https://audiomotion.app/)
- [Radial Audio Spectrum Tutorial — After Effects CC](https://www.youtube.com/watch?v=YLwi97erH1U)
- [GLava — OpenGL audio spectrum visualizer with radial module](https://github.com/jarcode-foss/glava)
- [Inigo Quilez — 2D SDF primitives (pie / arc)](https://iquilezles.org/articles/distfunctions2d/)
- [Octave-band analysis: mathematical rationale (CRYSOUND)](https://www.crysound.com/octave-band-analysis-the-mathematical-and-engineering-rationale/)
- [Shadertoy — Smooth Symmetric Polar Mod](https://www.shadertoy.com/view/NdS3Dh)
- [Better SDF Anti-Aliasing — Shadertoy](https://www.shadertoy.com/view/3XfcRf)
