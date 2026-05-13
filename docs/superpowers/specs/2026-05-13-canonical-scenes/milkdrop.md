# Milkdrop — canonical Winamp-era feedback visualizer

Status: design spec (rewrite target). Owner: Milkdrop scene.

## Visual goal

A frame-feedback fluid: each frame, the **previous frame's image is sampled
through a warped UV** (zoom in slightly, rotate slightly, push outward at the
edges), darkened by a decay constant (~0.97), and then the **audio waveform is
drawn on top as a glowing line**. Over many frames the trails of past
waveforms swirl, stretch, fold, and decay into the background — exactly the
"liquid plasma with a bright signature curve riding on top" look that defined
Geiss/Nullsoft MilkDrop (1.x/2.x) for two decades of Winamp users, and that
Butterchurn carried to the web. The current scene in this repo is a procedural
fbm-domain-warp lava lamp — it has the right *colors* but **none of the
recursive feedback** that makes Milkdrop look like Milkdrop. The single most
important thing to fix is that **last frame's pixels must feed into this
frame's pixels** through a ping-pong texture; everything else is decoration.

References:
- Butterchurn live demo (canonical reference look): https://butterchurnviz.com/
- Butterchurn GitHub (WebGL port of Milkdrop 2): https://github.com/jberg/butterchurn
- projectM (C++ open-source Milkdrop): https://github.com/projectM-visualizer/projectm
- Ryan Geiss preset authoring guide (zoom/rot/cx/cy/sx/sy/warp): https://www.geisswerks.com/milkdrop/milkdrop_preset_authoring.html
- Pixel Shader Basics (the `ret = tex2D(sampler_main, uv) * 0.97` idiom): http://wiki.winamp.com/wiki/Pixel_Shader_Basics

## Inputs

Provided to every scene each frame:

| Input                | Type             | Notes                                          |
|----------------------|------------------|------------------------------------------------|
| `spectrum.bands`     | `[Float]` len 64 | linear-frequency FFT magnitudes, ~0..1         |
| `spectrum.rms`       | `Float`          | overall loudness ~0..1                         |
| `waveform`           | `[Float]` 1024   | PCM in [-1, 1]                                 |
| `beat`               | `BeatEvent?`     | `strength` in [0,1] on transients              |
| `dt`                 | `Float`          | seconds since last frame                       |
| uniforms             | —                | `time, aspect, rms, beatStrength` already wired |

Derived per-frame audio (computed on CPU, low-pass smoothed):

- `bass`   = mean of bands `[0..4]`     (sub + low)
- `mid`    = mean of bands `[8..24]`
- `treble` = mean of bands `[40..63]`
- `vol`    = `rms` (or `(bass+mid+treble)/3`)

Smooth each with `x += (target - x) * (1 - exp(-dt / tau))`. Use `tau = 0.12 s`
for bass/mid (Milkdrop's "_att" attack), `tau = 0.05 s` for treble. The decay
constant on the feedback texture must be **frame-rate-independent**; see step 2.

## Algorithm — Milkdrop's two-pass feedback loop

Each frame runs three GPU passes plus one CPU vertex-buffer build:

```
prev  --[warp pass]-->  curr  --[waveform pass]-->  curr  --[composite]-->  screen
 ^___________________________________________________|
                       (next frame's prev)
```

Two offscreen textures (`texA`, `texB`) ping-pong. At the start of each frame
`prev` = the one that was rendered into last frame; we render into the other
one as `curr`, then swap.

### Step 1 — set up the two feedback textures

On scene build:

- Allocate **two** `MTLTexture`s sized to the drawable (or a fixed internal
  resolution like 1024 × 1024 — Milkdrop historically rendered at a lower
  internal resolution and upsampled in the composite pass; matching drawable
  size is fine for modern GPUs and avoids resampling artifacts).
- Pixel format: `bgra8Unorm_srgb` (matches the rest of the app, lets the
  decay multiplication look perceptually correct).
- `usage = [.renderTarget, .shaderRead]`, `storageMode = .private`.
- On the very first frame, clear both to black so the first warp samples
  black instead of garbage.

The composition root never touches these — they're internal to
`MilkdropScene`. The scene owns a `parity: Int` (0 or 1); each frame
`prev = textures[parity]`, `curr = textures[1 - parity]`, then flip.

If the drawable size changes (window resize), reallocate both textures and
clear them. Treat that as a one-frame visual glitch — acceptable.

### Step 2 — warp pass (the feedback heart of the algorithm)

A single fullscreen-quad fragment shader writes `curr`. It samples `prev` at
a **warped UV** and multiplies by the decay constant.

```metal
// fragment input: uv in [0, 1] (texture-space), or [-1, 1] aspect-corrected
// pos for math, then mapped back to [0,1] for the texture sample.
float2 p = uv * 2.0 - 1.0;     // -> [-1, 1]
p.x *= aspect;                 // square pixels for the math

// --- Milkdrop's per-pixel motion equation, simplified to a fixed preset ---
// All five terms are independently audio-coupled.

// 1) zoom: pulse inward slightly each frame; beats kick it harder.
float zoom = 1.0 - (0.005 + 0.020 * bass + 0.040 * beatStrength);
// 0.97..0.995 typical. <1.0 means we sample from a slightly larger ring,
// so the image appears to zoom IN over time. >1.0 zooms out.

// 2) rotation: slow constant spin + bass-coupled wobble.
float rot = 0.010 * dt_factor                       // ~0.6 deg/frame at 60fps
          + 0.040 * sin(time * 0.30) * bass         // bassy wobble
          + 0.080 * beatStrength;                   // kick on the beat
// dt_factor = dt * 60.0, so values stay frame-rate-independent.

// 3) cx, cy: center of zoom/rotation. Drift it slowly so the vortex
//    doesn't sit dead-center forever.
float2 center = 0.10 * float2(sin(time * 0.13), cos(time * 0.17));

// 4) warp: per-pixel sinusoidal displacement (Milkdrop's "warp" knob).
//    This is what gives the swirling, organic feel — without it, the
//    feedback is just a smooth zoom-rotate.
float warpAmt = 0.015 + 0.025 * bass;
float2 warp = warpAmt * float2(
    sin(p.y * 5.7 + time * 1.30),
    cos(p.x * 6.3 + time * 1.10)
);

// 5) compose: rotate, scale around `center`, add warp.
float c = cos(rot), s = sin(rot);
float2 q = p - center;
q = float2(c * q.x - s * q.y, s * q.x + c * q.y);   // rotate
q *= zoom;                                          // scale (around 1.0)
q += center + warp;

// Back to texture space.
q.x /= aspect;
float2 prevUV = q * 0.5 + 0.5;

// --- the iconic two-line warp shader ---
float3 ret = prev.sample(linearClamp, prevUV).rgb;
ret *= decay;                                       // 0.96..0.99, see below

return float4(ret, 1.0);
```

Why these specific numbers:

- **`zoom ≈ 0.98`**: 0.98^60 ≈ 0.30, so a pixel at the edge takes about a
  second to reach the center. Slower than 0.995 (too static), faster than
  0.95 (everything sucks into the middle in under half a second).
- **`decay ≈ 0.97`**: 0.97^100 ≈ 0.05 — about 100 frames (1.6 s @ 60 fps) of
  visible history. Quoted directly from Geiss's pixel-shader docs. **<0.94
  and the screen goes black between waveform draws.** >0.99 and the image
  saturates to a uniform color and never resets.
- **`warpAmt ~ 0.02`**: small enough that pixels travel <2% of the screen
  per frame; too large and the feedback becomes chaotic and detail-free.
- **rotation in radians per frame, scaled by `dt*60`** so the look matches
  at 30, 60, 120 Hz refresh rates.

Sampler: `filter::linear`, `address::clamp_to_edge` (Milkdrop uses border
clamp — sampling outside [0,1] returns the edge color, which compounds with
decay to fade the borders to black naturally).

### Step 3 — waveform overlay pass

Render `curr` as the target again (same texture, second pass), this time
with **additive blending**, drawing the waveform as a line strip on top of
the warped feedback. This is the "bright signature curve" that gives every
Milkdrop preset its identity.

CPU side (`update`), build a vertex buffer of `N=512` line-strip points:

```swift
// Sample 512 points from the 1024-sample waveform (decimate by 2).
// Center the curve at screen center; map -1..1 PCM to a screen-space y.
let N = 512
for i in 0..<N {
    let t = Float(i) / Float(N - 1)        // 0..1 along the wave
    let s = waveform[i * 2]                // PCM in [-1, 1]

    // Default Milkdrop wave is roughly a circle that breathes with PCM.
    // The "amplitude" is added along the curve's normal direction.
    let theta = t * 2.0 * .pi
    let baseR: Float = 0.45                 // base ring radius
    let amp:   Float = 0.18 + 0.25 * rms    // RMS-coupled fatness
    let r = baseR + s * amp

    let x = r * cos(theta)
    let y = r * sin(theta)
    vertices[i] = SIMD2<Float>(x, y)
}
```

Variant shapes (selectable via `randomize()`):

- **Circle** (default, as above).
- **Horizontal line**: `x = lerp(-0.8, 0.8, t)`, `y = s * amp`.
- **Figure-eight (lissajous)**: `x = 0.6*sin(2*theta)`, `y = 0.6*sin(theta) + s*amp*normal`.

For the circle/figure-eight, displace **along the local normal** so the
sample modulates *radially* (the iconic Milkdrop look). For the horizontal
line the normal is just `(0, 1)`.

GPU side: a tiny line-strip pipeline with `lineWidth` baked into geometry
(Metal doesn't do thick lines natively — emit a triangle strip instead, two
vertices per sample at ±half-thickness along the normal). Use a fragment
shader that:

1. Picks the line color from the palette texture, indexed by `t + rms*0.2`
   (so the line cycles colors with intensity).
2. Multiplies by an alpha falloff `exp(-d*d / sigma^2)` where `d` is
   distance from the line's center (gives a soft glow).
3. Outputs `vec4(rgb, 1)` with **additive blending** in the pipeline state
   (`sourceRGBBlendFactor = .one`, `destinationRGBBlendFactor = .one`,
   `rgbBlendOperation = .add`). Saturating against the decayed background
   is how Milkdrop avoids the line ever looking dull.

Line thickness: ~1.5 px on a 1080p target (~0.0015 in NDC), inflated by
beat: `thickness = 1.5 + 4.0 * beatStrength` px.

### Step 4 — composite pass (final draw to screen)

Read `curr` and write it to the actual drawable. Two things happen here:

1. **Color grading**: optionally apply gamma curve and saturation boost
   so the palette is punchy without inflating the feedback decay (which
   would saturate the feedback texture).
2. **Bloom (optional, recommended)**: a cheap two-tap blur of bright
   regions, added back. Stage 2 — defer if budget is tight.

A minimal composite is literally:

```metal
float3 c = curr.sample(linearClamp, uv).rgb;
c = pow(c, float3(0.85));            // mild gamma lift
c *= 1.0 + 0.4 * beatStrength;       // beat brightness flash
return float4(c, 1.0);
```

Bloom (if implemented): downsample `curr` 2× into a third texture, apply a
9-tap Gaussian horizontally then vertically, threshold at 0.7, add back at
0.4 weight. Skip for the first cut — the additive waveform already glows.

### Step 5 — swap parity for next frame

```swift
parity = 1 - parity
```

That's the entire pipeline. Three passes (warp → wave → composite), two
textures, one line-strip vertex buffer, one palette texture.

## Critical numerical constants

| Symbol         | Value                              | Why                                              |
|----------------|------------------------------------|--------------------------------------------------|
| `decay`        | `0.97`                             | ~1.6 s history; <0.94 → black, >0.99 → saturate  |
| `zoom_base`    | `0.99`                             | gentle inward pull; +0.02 on beat                |
| `rot_base`     | `0.010` rad/frame @ 60fps          | ~0.6°/frame, scaled by `dt*60`                   |
| `warpAmt_base` | `0.015`                            | +0.025 × bass; cap total at 0.06                 |
| `center_drift` | `0.10`                             | NDC; slow elliptical wander                      |
| `wave_radius`  | `0.45`                             | base circle in aspect-corrected NDC              |
| `wave_amp`     | `0.18 + 0.25 × rms`                | RMS-coupled radial swing                         |
| `wave_thick`   | `1.5 px + 4 × beat`                | ~3 NDC units / drawableHeight on retina          |
| `wave_samples` | `512`                              | decimate 1024 PCM by 2                           |
| `internal_res` | drawable size                      | match window; reallocate on resize               |
| `bloom_thresh` | `0.7`                              | only the brightest hot spots feed the bloom      |
| `gamma`        | `0.85`                             | mild lift; the feedback already darkens edges    |

All audio modulators are clamped to [0,1] before being scaled, so beat
spikes can't drive zoom past `0.92` (which would blow the image apart).

## Common pitfalls

1. **Decay too low → screen turns black.** `decay = 0.9` looks fine
   statically but the waveform vanishes between draws and there's no visible
   trail. Stay in `[0.96, 0.99]`.
2. **No ping-pong → "feedback to self" → undefined.** A render pass cannot
   sample its own color attachment. You **must** have two textures and
   alternate which is read vs written each frame.
3. **Warp too strong → everything collapses to a point.** If `zoom < 0.93`
   plus `warpAmt > 0.08`, every pixel converges to the center within ~30
   frames and the image becomes a uniform color. Test by holding bass at
   its max and confirming the image still has visible detail after 2 s.
4. **No additive blend on the waveform → line vanishes under decay.**
   Without `.one + .one`, the waveform line is drawn as opaque pixels which
   are then darkened by the next frame's decay; visually correct, but the
   line never glows. Additive lets repeated draws of nearby pixels build up
   above 1.0 (clamped at composite), which is what creates the bloom hot
   spots.
5. **Frame-rate sensitivity.** `zoom *= 0.98` each frame means a 30 Hz
   monitor zooms half as fast as a 60 Hz one. Scale audio-coupled deltas by
   `dt * 60.0` or use `pow(decay, dt * 60.0)`. The base preset look is
   tuned at 60 fps; without scaling, 120 Hz monitors look frozen.
6. **No center drift → the vortex sits at (0,0) forever** and the image
   develops a "drain in the middle" look. The slow `sin/cos` center wander
   is what makes long-duration footage stay interesting.
7. **Sampling `prev` with `repeat` addressing → wraparound artifacts.**
   The image tiles across the edges. Always `clamp_to_edge`.
8. **Aspect ratio applied only to the warp, not the waveform.** If the
   waveform circle is in raw NDC, it stretches to an ellipse on
   non-square windows. Apply `p.x /= aspect` to the waveform line geometry
   too (or scale `x` by `1/aspect` in the vertex shader).
9. **Resizing the drawable mid-session.** If the texture pair isn't
   reallocated, sampling becomes wrong-aspect and the image gets pinned to
   a corner. Reallocate + clear on resize.
10. **First-frame `prev` is uninitialized.** Without an explicit clear,
    the first warp pass samples garbage memory and you get colored static
    until decay washes it out (~2 seconds of ugliness).

## Comparison with current implementation

Current files: `AudioVisualizer/Infrastructure/Metal/Scenes/MilkdropScene.swift`
and `AudioVisualizer/Infrastructure/Metal/Shaders/Milkdrop.metal`.

What's there today:

- **Single-pass procedural fbm shader.** Two layers of value-noise domain
  warp + a bass-coupled rotation, sampled through the palette. No frame
  feedback at all — every frame is independent, computed from scratch.
- **No textures own state.** The scene holds `time, rms, bass, warp,
  swirl` as Swift floats and that's it. No ping-pong, no offscreen
  targets.
- **No waveform.** The 1024-sample PCM buffer passed in `update()` is
  ignored entirely. This is the single most visible miss — Milkdrop
  without the waveform overlay is just a screensaver.
- **No beat coupling.** `BeatEvent?` is accepted but not consulted.
- **`bass` is smoothed with a fixed `* 0.12` lerp** (not dt-scaled), so
  the smoothing rate drifts with framerate.
- Color: palette sampling is fine and already matches the rest of the
  app's palette texture convention — keep that.

### Gaps, in priority order

1. **No frame feedback** — biggest miss. Add two-texture ping-pong.
2. **No waveform line** — the iconic Milkdrop signature.
3. **No motion equation** — the procedural fbm has no `zoom/rot/cx/cy`
   in the Milkdrop sense.
4. **No beat coupling** — beats are received but unused.
5. **Frame-rate-dependent smoothing** — switch to `1 - exp(-dt/tau)`.
6. **No center drift** — image will look static in the long tail.

## Concrete fix list

1. Allocate two `MTLTexture`s in `build()`, sized to drawable, format
   `bgra8Unorm_srgb`, `[.renderTarget, .shaderRead]`, `.private`. Track a
   `parity: Int` and clear both on first frame and on resize.
2. Add a `resize(to: CGSize)` method to `VisualizerScene` (or, if the
   protocol can't change, lazy-reallocate inside `encode` when the
   drawable size differs from the cached size). Inspect
   `MetalVisualizationRenderer` for the canonical hook.
3. Replace the single `md_fragment` with **three** Metal functions:
   `md_warp_fragment`, `md_wave_vertex` + `md_wave_fragment`,
   `md_composite_fragment`. Wire three `MTLRenderPipelineState`s in
   `build()`, one per pass.
4. In `encode`, run pass 1 (warp) into `curr` with `prev` bound as
   texture, pass 2 (waveform line strip, additive blend) into `curr`,
   pass 3 (composite) into the actual drawable. Swap parity at the end.
5. Implement the per-pixel motion equation from step 2 above. All five
   modulators (`zoom, rot, center, warp`) must be audio-coupled and
   beat-spiked.
6. Build a 512-vertex circular waveform geometry on the CPU each frame
   from `waveform[]`. Expand to a triangle strip with thickness in the
   vertex shader (two verts per sample, offset ±half-thickness along the
   local normal). Aspect-correct in vertex space.
7. Add `BeatEvent` consumption in `update()`: latch `beatStrength` and
   decay it in `update` with `beatStrength *= exp(-dt / 0.15)` so a
   single beat fades over ~150 ms.
8. Replace the `bass += (target - bass) * 0.12` smoother with
   `bass += (target - bass) * (1 - exp(-dt / 0.12))` (and the same for
   mid/treble). Same numerical look, but framerate-independent.
9. Add `dt_factor = dt * 60.0` to the uniforms and use it to scale `rot`
   and beat decay so values match between 30/60/120 Hz.
10. Wire the waveform pipeline with additive blending
    (`sourceRGB/AlphaBlendFactor = .one`,
    `destinationRGB/AlphaBlendFactor = .one`, `blendOperation = .add`).
11. Update `randomize()` to also pick a waveform shape (circle / line /
    figure-eight) and a base palette offset; jitter `warpAmt_base` within
    `[0.010, 0.025]`. Keep `swirl` and `warp` as preset-tuned but
    randomized within sane ranges.
12. **Stretch goal — bloom**. Add a 4th pass: 2× downsample → 9-tap
    separable Gaussian → threshold 0.7 → add 0.4× back in composite. Skip
    on first cut; the additive waveform already produces a bloomy look.

## References

- Butterchurn live demo (canonical look in browser): https://butterchurnviz.com/
- Butterchurn source (WebGL port of Milkdrop 2): https://github.com/jberg/butterchurn
- projectM (cross-platform Milkdrop in C++): https://github.com/projectM-visualizer/projectm
- Ryan Geiss's preset authoring guide (zoom/rot/cx/cy/sx/sy/warp/decay): https://www.geisswerks.com/milkdrop/milkdrop_preset_authoring.html
- Pixel Shader Basics on Winamp wiki (the `ret = tex2D(sampler_main, uv) * 0.97` idiom): http://wiki.winamp.com/wiki/Pixel_Shader_Basics
- MilkDrop preset authoring HTML in foo_vis_milk2: https://github.com/jecassis/foo_vis_milk2/wiki/MilkDrop-2-Visualisation
- MilkDrop 2 source mirrored in milkdrop2-musikcube: https://github.com/clangen/milkdrop2-musikcube
- Wikipedia on MilkDrop history and BSD release: https://en.wikipedia.org/wiki/MilkDrop
