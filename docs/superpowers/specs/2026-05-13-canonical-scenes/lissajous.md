# Canonical Lissajous / XY Oscilloscope Scene — Design Spec

Date: 2026-05-13
Scene: `LissajousScene`
Status: design proposal, supersedes the current parametric-figure implementation

## 1. Visual goal

A real analog **stereo phosphor goniometer**: a glowing green/cyan trace that paints
the live (L, R) sample pair onto an XY plane, rotated 45° so mono content stacks as
a thin vertical line and out-of-phase content fans out horizontally. The trace
leaves an exponentially-fading afterimage on the screen (phosphor persistence)
and is **brightest where the beam moves slowly** and dim where it sweeps quickly
— exactly the way a real CRT works when the beam current is constant but the
phosphor's exposure time per unit area depends on dwell time. The current
"parametric Lissajous figure driven by `time`" must be replaced: it does not
react to the actual stereo image of the audio at all.

References for the look:
- Voxengo SPAN / SPAN Plus goniometer pane (mastering plugin).
- RTW TouchMonitor 31960 audio vectorscope (broadcast hardware).
- Tektronix 465 / 2465 in XY mode (analog scope, P31 green phosphor).

## 2. Inputs

Per frame the scene receives (see `VisualizationRendering.consume`):
- `spectrum.bands: [Float]` — 64 linear-frequency bands, used only for the `rms`-derived hue shift.
- `waveform: [Float]` — **today** 1024 mono PCM samples in [-1, 1].
- `beat: BeatEvent?` — strength in [0, 1].
- `dt: Float`, uniforms `time, aspect, rms, beatStrength`.

**Assumption used by this spec**: the implementer will introduce a parallel
`waveformStereo: [Float]` of length **1024 = 512 stereo pairs interleaved as
[L0, R0, L1, R1, …, L511, R511]** sourced from the Core Audio tap before
downmixing. The current mono waveform is the average `(L+R)/2` and contains
zero phase information — a true XY scope is impossible without the original
two channels.

If the stereo array is empty the scene must fall back to plotting `(w[i], w[i+1])`
from the mono waveform: the result is a thin diagonal "mono line", which is
the visually correct degenerate answer.

## 3. Algorithm, step-by-step

### 3.1 Stereo decode → Mid/Side rotation by 45°

Given interleaved pairs `(L_k, R_k)` for `k = 0 … N-1` (N = 512):

```
M_k = (L_k + R_k) / sqrt(2)        // mid (sum)   — perceptual "center"
S_k = (L_k - R_k) / sqrt(2)        // side (diff) — perceptual "width"
x_k = S_k                          // horizontal axis  = sides
y_k = M_k                          // vertical axis    = center
```

This is the canonical broadcast / mastering orientation (RTW, Apple Logic Pro
Multimeter, Voxengo). Why mastering engineers want it that way:
1. A perfectly mono signal lands on `S = 0` → a vertical line. Mono compatibility
   is read off in one glance: any horizontal spread is energy that will collapse
   when the listener sums to mono.
2. Out-of-phase content (`R = -L`) lands on `M = 0` → a horizontal line — visually
   alarming, which is exactly what you want for a phase problem.
3. The amplitude envelope of a normal stereo mix forms a vertical "ball of wool"
   slightly taller than wide. Width is read as the cloud's horizontal extent.

The `/√2` factor preserves energy: `M² + S² = L² + R²`, so the trace stays inside
the unit disk for `|L|, |R| ≤ 1`.

### 3.2 Curve interpolation — Catmull-Rom over N = 4 control samples

Plotting the 512 raw points as line segments looks staircased at any non-trivial
window size, because consecutive PCM samples in stereo program material can
jump several percent of full scale. Use a **uniform Catmull-Rom cubic spline**
through every 4 consecutive `(x, y)` pairs and subdivide each segment into
`SUBDIV = 8` rendered micro-segments. Final rendered count: `(N-3) * 8 = 4072`
short segments per frame.

For 4 control points `P_0 = (x_{k-1}, y_{k-1})`, `P_1 = (x_k, y_k)`,
`P_2 = (x_{k+1}, y_{k+1})`, `P_3 = (x_{k+2}, y_{k+2})`, the spline between
`P_1` and `P_2` is parameterised by `t ∈ [0, 1]`:

```
p(t) = 0.5 * (
    (2 P_1) +
    (-P_0 + P_2) t +
    (2 P_0 - 5 P_1 + 4 P_2 - P_3) t^2 +
    (-P_0 + 3 P_1 - 3 P_2 + P_3) t^3
)
```

(Reference: Iñigo Quilez, "Catmull-Rom splines".) Evaluate at
`t = j / SUBDIV` for `j = 0 … SUBDIV-1`. Run this in C++ in
`VisualizerKernels` so the Metal vertex stage only consumes a flat
`segmentBuffer: [Float2]` of length `(N-3) * SUBDIV + 1`.

### 3.3 Anti-aliased line rendering — SDF segment per pixel

Each adjacent pair of points in `segmentBuffer` is drawn as an instanced quad
(same shape as the current shader). The fragment runs a signed-distance check
against the line segment and uses screen-space derivatives to anti-alias:

```metal
float2 pa = uv - a;
float2 ba = b - a;
float h  = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
float d  = length(pa - ba * h);              // signed distance to the segment
float w  = fwidth(d);                         // pixel footprint
float aa = 1.0 - smoothstep(halfWidth - w, halfWidth + w, d);
```

`fwidth` gives resolution-independent edge softening; `aa ∈ [0,1]` is the
final coverage. Two passes are kept (outer glow + crisp core), but the
outer pass uses `halfWidth ≈ 0.012` NDC and the core pass uses
`halfWidth ≈ 0.0025` NDC — a real CRT trace is much thinner than the
current 0.018 / 0.005.

### 3.4 Phosphor persistence — ping-pong framebuffer with exponential decay

This is the single change that makes the scene *look like a scope* instead
of like a string of glowing dots.

- Allocate two offscreen `MTLTexture`s `tex_A, tex_B`, same size as the
  drawable, format `rgba16Float` (HDR — additive blending without clipping).
- Each frame:
  1. **Decay pass**: render a full-screen quad sampling `tex_prev` and write
     `tex_curr.rgb = tex_prev.rgb * decay`, where
     `decay = exp(-dt / tau)` and `tau = 0.080` s (80 ms). At 60 fps,
     `decay ≈ 0.811`.
  2. **Trace pass**: draw the segments with `sourceRGBBlendFactor = .one,
     destinationRGBBlendFactor = .one` (purely additive) into `tex_curr`.
  3. **Resolve**: blit `tex_curr` to the drawable, optionally with a cheap
     two-tap horizontal+vertical blur for the bloom halo.
  4. Swap `tex_prev ↔ tex_curr`.

`tau = 80 ms` matches the medium-persistence P31 green phosphor used in
analog scopes well enough that the trace history feels alive but doesn't
smear past one beat at 120 BPM (500 ms). Expose it as a knob; values in
the 40–250 ms range are all musically useful.

### 3.5 Beam intensity = inverse of beam speed

A real CRT has roughly constant beam current, so the per-pixel energy
deposited is proportional to the time the beam spends crossing that pixel
— i.e. inversely proportional to the beam's screen-space velocity.

For segment `k` with endpoints `p_k, p_{k+1}`:

```
speed_k    = length(p_{k+1} - p_k) * sampleRate   // NDC units per second
intensity_k = clamp(BEAM_REF / (speed_k + EPS), 0.05, 1.0)
```

`BEAM_REF` is calibrated so the *average* segment maps to intensity ≈ 0.4.
The Catmull-Rom subdivision is essential here: without subdivision, fast
sections of the waveform draw very few segments and the inverse-speed
rule produces a sparse dim trace; with `SUBDIV = 8` the segments are short
and uniform in screen length, so dwell-time really maps to brightness.

This is what makes the scope look "right". Sustained mono passages dwell
on the vertical axis and burn it bright; transient stereo content sweeps
across the disk and looks faint and ghostly — exactly the goniometer feel
mastering engineers know.

### 3.6 Audio coupling beyond stereo

- **Beat brightness boost**: multiply the trace pass intensity by
  `1.0 + 0.6 * beatStrength` for the frame a beat fires; decay back over
  120 ms. Gives the scope a subtle "hit" on each kick.
- **RMS hue shift**: rotate the palette sample's u-coordinate by
  `0.10 * smoothstep(0.05, 0.35, rms)` so the trace drifts from cyan-green
  (quiet) to warm green-amber (loud), mimicking phosphor blooming under
  high beam current.
- **Correlation tint** (optional, costs one accumulator): compute
  `corr = Σ L_k R_k / sqrt(Σ L_k² Σ R_k²)` over the frame's samples and
  tint the persistence-pass clear color very faintly red when
  `corr < -0.1` (out-of-phase warning).

## 4. Critical numerical constants

| Symbol      | Value                          | Notes                                              |
|-------------|--------------------------------|----------------------------------------------------|
| `N`         | 512 stereo pairs / frame       | matches current 1024-sample mono waveform          |
| `SUBDIV`    | 8 segments per Catmull-Rom span| `(N-3)*8 = 4072` line segments                     |
| `tau`       | 0.080 s                        | phosphor decay; `decay = exp(-dt/tau) ≈ 0.811@60fps`|
| `halfWidth` | 0.0025 NDC (core), 0.012 (glow)| true scope trace is thin                           |
| `BEAM_REF`  | calibrated so mean ≈ 0.4       | inverse-speed brightness reference                 |
| `EPS`       | 1e-4                           | guards inverse-speed at zero velocity              |
| `rotation`  | 45° (M/S basis)                | `M = (L+R)/√2, S = (L-R)/√2`                       |
| Plot scale  | 0.92                           | leaves room for halo inside NDC ±1                 |
| HDR format  | `rgba16Float`                  | additive accumulation without saturation           |

## 5. Common pitfalls

1. **Drawing N independent points instead of N-1 segments.** Produces a dotty
   "stipple" instead of a continuous trace. Always draw line segments (or
   spline micro-segments) between consecutive samples.
2. **No persistence.** Without the ping-pong decay buffer the trace looks
   like a thin nervous string of light; with it, it looks like a CRT. This
   is the single highest-leverage change.
3. **Ignoring M/S rotation.** Plotting raw `(L, R)` onto the screen axes
   makes mono content appear as a 45° diagonal line, which broadcast
   engineers correctly read as "the picture is tilted". Always rotate.
4. **Drawing without inverse-speed brightness.** Uniform-brightness traces
   look like vector-graphics line art, not a scope. The inverse-speed rule
   is what separates the look.
5. **Using the existing mono waveform as both X and Y.** The current scene
   feeds `vk_lissajous` a `time` parameter — it produces a parametric
   figure that has nothing to do with the audio's stereo image. Must be
   replaced with the real `(L_k, R_k)` data.
6. **8-bit accumulation buffer.** Additive blending into `bgra8Unorm` clips
   instantly on loud passages and stairsteps on quiet ones. Use
   `rgba16Float`.
7. **Drawing the decay pass with the same blend state as the trace pass.**
   The decay pass must overwrite (multiplicative), not add — otherwise the
   buffer just grows monotonically and the trace whites out within seconds.

## 6. Comparison with current implementation

Files inspected:
- `/Users/sebastiancardonahenao/development/audio-video-gen/.claude/worktrees/youthful-almeida-53ac93/AudioVisualizer/Infrastructure/Metal/Scenes/LissajousScene.swift`
- `/Users/sebastiancardonahenao/development/audio-video-gen/.claude/worktrees/youthful-almeida-53ac93/AudioVisualizer/Infrastructure/Metal/Shaders/Lissajous.metal`
- `/Users/sebastiancardonahenao/development/audio-video-gen/.claude/worktrees/youthful-almeida-53ac93/Vendor/VisualizerKernels/VisualizerKernels.cpp` (`vk_lissajous`, `vk_rose`)

Gaps vs. canonical scope:

| Aspect                  | Current                                          | Canonical                                  |
|-------------------------|--------------------------------------------------|--------------------------------------------|
| Data source             | parametric `sin(aθ+δ), sin(bθ)` driven by `time` | live `(L, R)` from stereo PCM              |
| Stereo decode           | none                                             | M/S 45° rotation                           |
| Sample-to-sample smoothing | none (point buffer is raw)                    | Catmull-Rom × 8 subdivisions               |
| Persistence             | none — every frame is fresh                      | ping-pong `rgba16Float` with `exp(-dt/τ)`  |
| Beam brightness         | constant per pass, scaled by `rms`               | inverse of segment screen-speed            |
| Line AA                 | edge defined by quad geometry only               | SDF + `fwidth` per fragment                |
| Accumulation precision  | `bgra8Unorm_srgb`                                | `rgba16Float`                              |
| Color                   | palette texture lookup along trace length        | phosphor green/cyan, rms-shifted hue       |
| Beat reactivity         | implicit via `rms`                               | explicit `beatStrength` boost              |
| Mode "rose"             | unrelated polar curve                            | remove — not a scope                       |

## 7. Concrete fix list

1. **[PREREQUISITE]** Extend the capture pipeline to expose
   `waveformStereo: [Float]` (interleaved L/R, 512 pairs/frame) in
   `SystemAudioCapturing` and plumb it through `consume(...)` down to the
   scene. Until this lands, the scope falls back to mono `(w[i], w[i+1])`.
2. Add `vk_scope_xy(const float *lr, float *out, uint32_t pairs, ...)` to
   `VisualizerKernels`. It performs the M/S rotation, Catmull-Rom
   subdivision, and outputs both `(x, y)` and per-segment `intensity`
   (inverse speed).
3. Replace `vk_lissajous` / `vk_rose` calls in `LissajousScene.update` with
   the new kernel. Drop `modeIsRose`, `aBase/bBase`, etc. — they describe a
   different scene entirely (move the rose figure to a separate `RoseScene`
   if we want to keep it).
4. Add a ping-pong renderer: two `rgba16Float` textures sized to the
   drawable; a decay pass (full-screen quad multiplying by
   `exp(-dt / 0.080)`); a trace pass with additive blending into the
   current target.
5. Rewrite `Lissajous.metal`:
   - `lissajous_vertex` consumes `(p0, p1, intensity)` per instance.
   - `lissajous_fragment` computes SDF distance to the segment in the
     fragment, uses `fwidth` for AA, and multiplies by per-segment
     `intensity` (already inverse-speed scaled in the kernel).
6. Drop the `bgra8Unorm_srgb` color attachment on the trace pipeline in
   favor of the offscreen `rgba16Float` target. Final blit to the drawable
   tonemaps with a simple `1 - exp(-c)` or `c / (1+c)`.
7. Tune constants: `tau = 0.080 s`, core half-width `0.0025`, glow half-width
   `0.012`, plot scale `0.92`, `SUBDIV = 8`.
8. Wire `beatStrength` and `rms` into the trace pass uniforms: brightness
   boost on beat, hue shift with rms.
9. Add a unit test `VisualizerKernelsTests.test_scope_xy_rotates_mono_to_vertical_line`
   that feeds `L == R` into the kernel and asserts every output `x ≈ 0`.
10. Delete the `randomize()` random-figure logic from this scene — a scope
    has no random alternates. Replace with a per-click `tau` cycle (40 / 80
    / 160 ms) if we want a click-to-tweak affordance.

## 8. References

- Iñigo Quilez, "Catmull–Rom splines" — formula and matrix form.
  <https://iquilezles.org/articles/minispline/>
- Iñigo Quilez, "2D distance functions" — segment SDF.
  <https://iquilezles.org/articles/distfunctions2d/>
- RTW, "Focus: The Audio Vectorscope" — 45° rotation, in-phase / out-of-phase patterns.
  <https://www.rtw.com/en/blog/focus-the-audio-vectorscope.html>
- Sound On Sound, "What are my phase-correlation meters telling me?" — interpreting goniometer shapes.
  <https://www.soundonsound.com/sound-advice/q-what-are-my-phase-correlation-meters-telling-me>
- Voxengo SPAN user guide (correlation meter / phase scope).
  <https://www.voxengo.com/files/userguides/VoxengoSPAN_en.pdf/getbyname/Voxengo%20SPAN%20User%20Guide%20en.pdf>
- DrSnuggles, `jsGoniometer` — JS reference implementation of a stereo goniometer.
  <https://github.com/DrSnuggles/jsGoniometer>
- Blur Busters, "CRT Simulation in a GPU Shader" — phosphor decay + beam-intensity modulation.
  <https://blurbusters.com/crt-simulation-in-a-gpu-shader-looks-better-than-bfi/>
- Matt DesLauriers, "Drawing Lines is Hard" — antialiased thick-line rendering survey.
  <https://mattdesl.svbtle.com/drawing-lines-is-hard>
