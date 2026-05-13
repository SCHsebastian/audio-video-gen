# Canonical Oscilloscope (Scope) Scene — Design Spec

Status: design reference for rewriting `AudioVisualizer/Infrastructure/Metal/Shaders/Scope.metal`
and `AudioVisualizer/Infrastructure/Metal/Scenes/ScopeScene.swift`.

## Visual goal

A single, crisp, anti-aliased glowing horizontal trace that traverses the screen
left-to-right and rises/falls with the instantaneous PCM amplitude — the classic
"oscilloscope view" from Winamp's Scope, Cool Edit Pro / Adobe Audition, Audacity's
zoomed-in waveform, and every hardware analog scope. The line must look **still**
on a steady tone (no jelly/jitter) and must **remain a one-pixel-thin smooth glow
core with a wide soft halo**, never an aliased zig-zag. Beats brighten the core
without thickening the geometry. Optional CRT-style persistence trail.

References (visual targets):

- Winamp 2.x Scope (green single-line trace): https://winampheritage.com/visualization/osciloscope-and-vu-meter/148149
- woscope (CRT-accurate Gaussian beam oscilloscope, WebGL): https://m1el.github.io/woscope-how/
- Audacity zoomed waveform (peak + RMS envelope): https://manual.audacityteam.org/man/audacity_waveform.html

## Inputs (each frame)

| Name | Type | Notes |
|---|---|---|
| `waveform` | `[Float]` length 1024 | mono PCM, range `[-1, +1]`, sample rate 48 kHz, newest sample at the end |
| `spectrum.rms` | `Float` | RMS of the current frame, `[0, ~1]` |
| `beat.strength` | `Float?` | `[0, 1]` if a beat fired this frame |
| `dt` | `Float` | frame delta seconds |
| `uniforms.time` | `Float` | seconds since start |
| `uniforms.aspect` | `Float` | viewport `width/height` |

1024 samples @ 48 kHz = **21.3 ms** of audio per frame — long enough to display
~2 cycles of a 100 Hz signal, ~21 cycles of 1 kHz, ~21 ms of speech.

## Algorithm — step by step

### 1. Trigger sync (the most important step)

Without this the line jitters left/right every frame as the FFT window
slides over the audio and the visualizer looks like wobbling jelly. With it,
any periodic signal locks to a fixed horizontal phase.

```
// Input: w[0..N-1], N = 1024
// Output: triggerOffset in samples, 0 <= triggerOffset <= N/2

leadingOffset = N / 4          // 256: skip the first quarter so we always have N/2 samples to display after the trigger
hysteresis    = 0.02            // ±2% of full scale, kills noise re-triggers near zero
searchEnd     = N - displayLen  // = N/2; never trigger past where we'd run out of samples

triggerOffset = leadingOffset   // fallback: no zero-crossing found -> show raw tail

for i in leadingOffset ..< searchEnd:
    if w[i-1] < -hysteresis and w[i] >= +hysteresis - small_eps:   // strict rise across zero band
        triggerOffset = i
        break
    // simpler/looser variant that also works well:
    // if w[i-1] <= 0 and w[i] > 0 and (w[i] - w[i-1]) > hysteresis: break
```

Then build the display by reading `w[triggerOffset .. triggerOffset + displayLen - 1]`.

Why a **leading offset of N/4**: we need samples both before *and* after the
trigger so the visible window is N/2 long. Searching only in the middle half
guarantees we never overrun the buffer.

Why **hysteresis**: a pure `w[i-1] < 0 && w[i] >= 0` test fires on every
sample-rate-period zero-crossing of noise riding on the signal; the line still
jitters by 1–3 samples per frame. Requiring the signal to leave a deadband of
±0.02 around zero with positive slope reproduces what a Schmitt-trigger does in
hardware. (See Pico Tech's writeup on digital trigger hysteresis.)

Why **positive slope only**: a sine that rises through zero and one that falls
through zero land at the same x but with opposite phase. Pinning slope = + makes
the displayed waveform shape stable across frames.

### 2. Downsampling 1024 → N display points

Choose `displayLen = N/2 = 512` samples and **render every sample** — no further
decimation needed. 512 line segments at 1920 px wide = ~3.75 px per segment,
which is the regime where SDF rendering shines and no peaks are missed.

If a higher display point count is wanted (e.g. for a wider window), use a
**min/max envelope** per output bucket, not simple decimation:

```
for each output bucket b of width K samples:
    minVal[b] = min(w[b*K .. b*K+K-1])
    maxVal[b] = max(w[b*K .. b*K+K-1])
draw vertical bar from (x_b, minVal[b]) to (x_b, maxVal[b])
```

Min/max preserves transients that decimation drops. This is Audacity's
approach for its zoomed-out overview. For Scope at our default zoom we don't
need it — 512 segments at native rate is faithful — but the code path should be
available for future "wide view" modes.

### 3. Anti-aliased line rendering (SDF `sdSegment`)

The current scheme builds a fat triangle strip and softens edges with a Gaussian
across the strip thickness. That works for thick strips but breaks at high
slopes where the strip turns sideways and shows aliased steps. The canonical
fix is to **render each waveform segment as a quad and compute the signed
distance to the line in the fragment shader**, then alpha = `1 - smoothstep(0,
fwidth(d), d - core_radius)`.

Inigo Quilez's exact segment SDF in 2D:

```glsl
float sdSegment(float2 p, float2 a, float2 b) {
    float2 pa = p - a, ba = b - a;
    float h = clamp(dot(pa,ba) / dot(ba,ba), 0.0, 1.0);
    return length(pa - ba*h);
}
```

In Metal: each waveform segment (`p_i`, `p_{i+1}`) becomes a 6-vertex
oriented quad expanded along the perpendicular by `±max(thickness, 2*px)` so the
quad always covers the falloff radius even when the segment is nearly
horizontal. The fragment shader computes:

```
d = sdSegment(uv, a, b);                       // pixel distance to the line
w = fwidth(d);                                 // 1 pixel in screen space
core   = 1.0 - smoothstep(coreR,  coreR + w, d);     // sharp 1-px core
halo   = exp(-d*d / (haloSigma*haloSigma));          // gaussian glow
alpha  = core + halo * 0.6;
color  = mix(coolHueA, hotHueB, t) * alpha;          // gradient along trace
```

`coreR = 1.0 * px`, `haloSigma = 4.0 * px` for a normal scope; `haloSigma`
scales with `rms` so loud passages bloom.

Use **additive blending** so overlapping segments accumulate brightness like a
phosphor screen, matching woscope's `(SRC_ALPHA, ONE)` choice.

### 4. Vertical scaling

Quiet signals must remain visible without amplifying noise floor. Use a slow
auto-gain on top of a fixed headroom:

```
headroom    = 1.2                  // display range is [-1/1.2, +1/1.2] -> avoids touching the edges
targetPeak  = 0.7                  // we want the average loud signal at ±0.7
peakObserved = max(|w|) this frame
peakSmoothed += (peakObserved - peakSmoothed) * (peakObserved > peakSmoothed ? 0.5 : 0.05)
autoGain     = clamp(targetPeak / max(peakSmoothed, 0.05), 1.0, 8.0)
y_display    = clamp(sample * autoGain / headroom, -1, +1)
```

Fast attack (`0.5`), slow release (`0.05`) — this is the classic
auto-gain time constant ratio from audio meters. Hard ceiling of `8×` so
silence doesn't blow up the noise floor.

### 5. Color / palette mapping

A horizontal gradient along the trace, sampled from the shared `paletteTexture`
(LUT). Two contributions:

- **Position color**: `palette.sample(s, vec2(0.15 + t * 0.7, 0.5))` where
  `t = x / 1.0`. Skips the dimmest 15% of the LUT so the trace never looks gray.
- **Beat boost**: multiply RGB by `1 + 1.5 * beatStrength * exp(-3 * beatAge)`.
  Beats flash the whole trace whiter for ~250 ms, never widening the geometry.

### 6. Persistence / phosphor trail (optional)

Render the previous frame into an offscreen texture, multiply by `0.92` each
frame, and additively blit before drawing the new trace:

```
fade = pow(0.5, dt / halfLife)     // halfLife = 0.12 s gives the CRT feel
prev.rgb *= fade
```

Skip if FPS budget is tight — the SDF + halo already looks alive without it.

## Critical numerical constants

| Constant | Value | Reason |
|---|---|---|
| `N` (input samples) | 1024 | what we already produce |
| `leadingOffset` | 256 (= N/4) | leaves N/2 after trigger |
| `displayLen` | 512 (= N/2) | ~10.6 ms display window @ 48 kHz |
| `hysteresis` | 0.02 | ±2% dead-band kills noise re-trigger |
| `headroom` | 1.2 | display never clips at edges |
| `targetPeak` | 0.7 | comfortable visual loudness |
| `autoGain` range | `[1.0, 8.0]` | floor = unity, ceiling stops noise blowup |
| `attack` / `release` | 0.5 / 0.05 | fast-up / slow-down envelope |
| `coreR` | 1.0 px | sharp visible line |
| `haloSigma` | 4.0 px + rms·8 | bloom with loudness |
| `halo gain` | 0.6 | halo never overwhelms core |
| `palette t` range | `[0.15, 0.85]` | skip LUT extremes |
| `beat boost` | `1 + 1.5·s·e^(-3·age)` | bright flash, no geometric change |
| `phosphor halfLife` | 0.12 s | classic CRT decay |

## Common pitfalls

1. **No trigger sync** → jelly waveform: every frame the FFT window has slid
   by ~21 ms, so a 440 Hz sine looks like it's wiggling laterally. Trigger
   sync pins it to a stable phase.
2. **Pure decimation** at lower display rates drops fast transients (drum
   hits look softer). Min/max envelope preserves them.
3. **No AA / thin strip** = 1-px line that breaks into ladders at high slopes.
   Even SwiftUI's `Path.stroke` has this. SDF + `fwidth` is the canonical
   shader-side fix.
4. **Single-pass strip with Gaussian across the strip width** (what we ship)
   looks great at horizontal segments and ugly at near-vertical segments
   because the strip's *perpendicular* axis flips. SDF makes the line look
   correct at every slope.
5. **No hysteresis** in the trigger → noise riding on the carrier causes
   re-triggers within the same period; the line still jitters even though
   you "have" trigger sync.
6. **Trigger search across the entire buffer** → can pick a crossing inside
   the last 50 samples and you don't have enough samples after it to fill
   the display. Always restrict search to `[leading, N - displayLen]`.
7. **No auto-gain** → quiet podcasts look flat-lined.
8. **Auto-gain without ceiling** → silence shows hardware self-noise as a
   loud fuzzy line.
9. **Additive blend with halo too wide** → bright passages saturate to white
   everywhere. Keep `halo gain` ≤ 0.6 and let beats do the brightening.
10. **Beat thickens geometry** → the line looks like it's breathing in
    width. Beats must change brightness only.

## Comparison with current implementation

Current `ScopeScene.swift` + `Scope.metal`:

- Takes the **tail** of the waveform (`waveform.suffix(1024)`) — **no trigger
  sync**, so periodic signals visibly jitter frame-to-frame.
- Runs `vk_scope_envelope` which removes DC and applies a 7-tap binomial
  low-pass. Binomial low-pass over the *display window* is a smoothing filter,
  not anti-aliasing — it hides high-frequency content the user paid for.
- Gain is `1 + min(2, rms*4)` — no smoothing, no ceiling, no headroom,
  jumps every frame.
- Renders one triangle strip 2 vertices wide using strip-perpendicular `±`
  thickness in NDC y. **Thickness lives in y-NDC, not in pixels**, so the
  apparent thickness varies with viewport height and aspect.
- The "AA" is `exp(-ny² * 4.5)` across the strip width — Gaussian across the
  strip's local y. Works on flat segments, falls apart on steep slopes.
- Two passes are drawn (alpha 0.9 and alpha 0.25 with 3× thickness) to fake a
  glow — wastes vertex work; one SDF pass with built-in halo does it
  cheaper.
- No phosphor persistence, no beat coupling, no color gradient (single LUT
  row).
- 1024 segments drawn — every input sample becomes geometry; can be halved
  to 512 with no visible loss.

## Concrete fix list

1. **Add trigger sync in CPU code** (Swift, in `update`): find first positive-slope
   zero-crossing in `[N/4, N/2]` with `±0.02` hysteresis; if none, fall back to
   `N/4`. Slice `w[trigger .. trigger + 512]` into the GPU buffer.
2. **Replace `vk_scope_envelope` with a pure DC-removal kernel** (no
   low-pass): subtract the per-frame mean only. The visualization should
   show the actual signal, not a smoothed version.
3. **Add smoothed auto-gain in Swift**: state-machine with `attack=0.5`,
   `release=0.05`, ceiling 8×; multiply samples before upload.
4. **Rewrite the Metal shader to draw 512 segments using `sdSegment`**: each
   segment becomes a 2-triangle quad expanded by `max(coreR + 4*halo,
   2*px)` along the segment normal. Compute distance in pixel space using
   `fwidth(d)` for AA.
5. **Pixel-space thickness**: pass a `pxPerNDC` uniform (= viewportHeight / 2)
   so `coreR` and `haloSigma` are in pixels, not NDC, and don't change with
   resolution.
6. **Single-pass glow**: combine sharp core (`smoothstep`) and gaussian halo
   in one fragment, kill the two-pass over-draw.
7. **Color gradient**: sample LUT with `vec2(0.15 + t*0.7, 0.5)` where `t`
   varies left-to-right; modulate brightness by `1 + 1.5·beat·exp(-3·age)`.
8. **Additive blending stays** (already correct) — but pre-multiply alpha so
   the halo doesn't double-add.
9. **Optional phosphor pass**: maintain a 2-texture ping-pong, fade by
   `pow(0.5, dt/0.12)` per frame, additive-blit before the new trace.
10. **Aspect-correct sampling**: respect `uniforms.aspect` when mapping the
    horizontal index to NDC `x`, so the trace fills width 1:1 instead of being
    stretched by tall viewports.

## References

- Inigo Quilez — 2D distance functions (`sdSegment`):
  https://iquilezles.org/articles/distfunctions2d/
- m1el — *How to draw oscilloscope lines with math and WebGL* (Gaussian
  electron-beam shader, additive accumulation):
  https://m1el.github.io/woscope-how/
- Audacity manual — waveform peak / RMS rendering, min-max summary blocks:
  https://manual.audacityteam.org/man/audacity_waveform.html
- Pico Technology — *Advanced digital triggers* (hysteresis on zero-crossing
  trigger): https://www.picotech.com/library/knowledge-bases/oscilloscopes/advanced-digital-triggers
- Teledyne LeCroy — *Oscilloscope basics: stabilizing waveform display*
  (positive-going edge trigger at 50% level):
  https://blog.teledynelecroy.com/2022/01/oscilloscope-basics-stabilizing.html
- Tektronix — *Oscilloscope systems and controls: triggering explained*:
  https://www.tek.com/en/documents/primer/oscilloscope-systems-and-controls
- numb3r23 — *Using fwidth for distance-based anti-aliasing*:
  http://www.numb3r23.net/2015/08/17/using-fwidth-for-distance-based-anti-aliasing/
- pkh — *Perfecting anti-aliasing on signed distance functions*:
  https://blog.pkh.me/p/44-perfecting-anti-aliasing-on-signed-distance-functions.html
