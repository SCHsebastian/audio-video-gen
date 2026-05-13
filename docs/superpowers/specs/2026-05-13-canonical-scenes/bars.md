# Canonical Spectrum Bars

## Visual goal

The classic Winamp / Windows Media Player / foobar2000 bars view: a row of
roughly 32–64 vertical bars whose heights track a **log-frequency,
log-magnitude (dB)** view of the audio spectrum. Each bar has a small floating
"peak cap" that snaps up to the highest recent value, holds for a moment, then
falls at a steady rate. Bars are stacked from the floor (or mirrored from a
horizontal centerline) with a vertical color gradient — usually green at the
floor, yellow midway, red at the top. Motion is *snappy on the way up* and
*slow and even on the way down*. Bass should not dominate; treble should not
be a flat carpet at the floor.

References:
- Winamp Classic Spectrum Analyzer (Mike Lynch) —
  https://winampheritage.com/visualization/classic-spectrum-analyzer/165966
- audioMotion-analyzer demo —
  https://audiomotion.dev/demo/
- foobar2000 `foo_vis_spectrum_analyzer` screenshots —
  https://github.com/stuerp/foo_vis_spectrum_analyzer

## Inputs

Per frame the scene receives:

- `spectrum.bands: [Float]` — 64 **linear-frequency** FFT magnitude bands in
  ~[0, 1], post-vDSP, covering [0, 24 kHz] (sample rate 48 kHz).
- `waveform: [Float]` — 1024 PCM samples in [-1, 1] (unused here).
- `beat: BeatEvent?` — optional, `strength ∈ [0, 1]`.
- `dt: Float` — frame interval in seconds.
- Uniforms: `time, aspect, rms, beatStrength`.

The 64 input bands are spaced **linearly** from 0 to 24 kHz, i.e. each band
covers 375 Hz. Bands 0–1 already overlap the inaudible DC/sub region;
bands 30+ cover the perceptually compressed treble region.

## Algorithm — step by step

### 1. Log-frequency band mapping (linear FFT bins → N display bars)

Choose a perceptual frequency range:

- `f_min = 40 Hz`  (below this, output is mostly room rumble / DC leak)
- `f_max = 16000 Hz`  (above this, content is usually noise / hiss)
- `N_bars ∈ {24, 32, 48, 64}`

For each output bar `k` in `[0, N_bars)`, compute the **lower** and **upper**
edge in Hz (constant-Q, base-2 / octave-equivalent):

```
f_lo(k) = f_min * (f_max / f_min) ^ ( k      / N_bars)
f_hi(k) = f_min * (f_max / f_min) ^ ((k + 1) / N_bars)
```

Map those edges to fractional indices in the **linear** band array of length
`M = 64`:

```
bin_per_hz = M / (sampleRate / 2)   // = 64 / 24000 ≈ 0.002667
i_lo(k)    = f_lo(k) * bin_per_hz
i_hi(k)    = f_hi(k) * bin_per_hz
```

The bar value is the **max** (or mean) over `[i_lo, i_hi)`. For the bars look,
**max** is preferred — it preserves transient spikes and prevents wide
high-frequency bars from being averaged to mush:

```
v_lin(k) = max( bands[floor(i_lo(k)) .. ceil(i_hi(k))-1] )
```

For low `k`, `i_hi(k) - i_lo(k) < 1` (one input bin spans many output bars):
sample with linear interpolation between the two surrounding bins instead of
max.

### 2. Magnitude → dB → [0, 1]

```
dB(k)   = 20 * log10( v_lin(k) + ε )      with ε = 1e-4
v_dB(k) = clamp( (dB(k) - dB_floor) / (dB_ceil - dB_floor), 0, 1 )
```

Defaults (matched to listening level of consumer playback):

- `dB_floor = -70`  — anything quieter than this is "silence", render at 0
- `dB_ceil  = -10`  — at this level the bar pegs the top

(Web Audio uses min=-100, max=-30 by default; that's tuned for raw PCM in
[-1, 1] but our `bands` are already vDSP-normalised magnitudes around 0.0–0.3,
so we shift the window up.)

### 3. Optional perceptual tilt

Real instrument spectra slope roughly -3 to -4.5 dB/octave at high frequencies
("pink" tilt). Most visualizers compensate with a +3 dB/octave **slope** so
treble bars don't sit at the floor:

```
slope_dB(k) = +3.0 * log2( f_center(k) / 1000 )      // 0 dB at 1 kHz
dB(k) += slope_dB(k)
```

Apply *before* the dB-floor clamp.

### 4. Attack/release smoothing (asymmetric one-pole)

Per bar, with state `s(k)`:

```
τ_attack  = 0.020 s   (20 ms)   // snappy rise
τ_release = 0.300 s   (300 ms)  // slow, legible decay

α_atk = 1 - exp(-dt / τ_attack)     // ≈ 0.56 at 60 Hz
α_rel = 1 - exp(-dt / τ_release)    // ≈ 0.055 at 60 Hz

α     = (v_dB(k) > s(k)) ? α_atk : α_rel
s(k) += (v_dB(k) - s(k)) * α
```

`s(k)` is the displayed bar height in [0, 1].

### 5. Peak marker ("falling cap")

Per bar, with state `p(k)` (peak position in [0, 1]) and `t_hold(k)` (seconds
of hold remaining):

```
peak_hold_time   = 0.50 s              // dwell at the apex
peak_fall_rate   = 0.60  units/s       // ≈ 0.6 of the bar height per second
                                       // (≈ 36 dB/s if the bar spans 60 dB)

if v_dB(k) >= p(k):
    p(k)       = v_dB(k)
    t_hold(k)  = peak_hold_time
else:
    if t_hold(k) > 0:
        t_hold(k) -= dt
    else:
        p(k) = max(s(k), p(k) - peak_fall_rate * dt)
```

The cap never falls below the live bar value — it tracks `s(k)` if the bar
catches up.

Render the cap as a thin filled bar (height ≈ 2–4 px in screen space)
centered at `p(k)`.

### 6. Beat-driven extras

- **No additive height boost.** Stacking `+beat * 0.18` onto `v` (current
  behavior) pumps every bar in unison and reads as "the whole spectrum is
  louder", which is wrong — a kick drum is bass energy, not full-band.
- Instead, **flash the palette**: add `beat * 0.15` to the value of the
  vertical color gradient (V in HSV) for ~80 ms after the beat.
- Optional: brighten the peak cap (`+0.3` luminance during the hold window).

## Critical numerical constants

| Symbol            | Default     | Range        | Why |
|-------------------|-------------|--------------|-----|
| `f_min`           | 40 Hz       | 20–80 Hz     | Below 40 Hz is mostly inaudible rumble. |
| `f_max`           | 16 kHz      | 12k–20 kHz   | Above 16 kHz is hiss; most music drops off. |
| `N_bars`          | 32/48/64    | 16–96        | < 16 looks crude; > 96 looks like a spectrogram. |
| `ε` (dB floor)    | 1e-4        | 1e-5–1e-3    | Prevents log10(0). 1e-4 ≈ -80 dB. |
| `dB_floor`        | -70 dB      | -80…-50 dB   | Anything quieter is silence. |
| `dB_ceil`         | -10 dB      | -20…0 dB     | Pegs top at typical playback peaks. |
| `slope`           | +3 dB/oct   | 0–4.5 dB/oct | Counteracts pink tilt; 0 = "true" spectrum. |
| `τ_attack`        | 20 ms       | 10–40 ms     | Lower = twitchy, higher = mushy. |
| `τ_release`       | 300 ms      | 200–500 ms   | The "Winamp linger". |
| `peak_hold_time`  | 500 ms      | 300–800 ms   | Lower = caps feel jittery. |
| `peak_fall_rate`  | 0.6 /s      | 0.3–1.0 /s   | Slower = "stuck", faster = caps invisible. |
| `gap_fraction`    | 0.15        | 0.05–0.25    | Visual gap between bars. |

## Common pitfalls

- **Linear frequency mapping** (using the raw 64 linear bands as 64 bars)
  crams everything below 1 kHz into the first 2–3 bars, so kick/bass barely
  register while the right half of the screen flickers on hi-hats only.
  **Fix:** log-frequency rebinning.
- **Skipping dB conversion** makes bars hug the floor because `v_lin` is
  almost always in [0, 0.3] — the top of the screen is dead pixels. **Fix:**
  20·log10 + window normalization.
- **Symmetric smoothing** (one `lerp(state, value, k)` with a single `k`)
  either makes everything sludgy (high smoothing) or jittery (low). **Fix:**
  asymmetric attack/release.
- **No peak caps** kills the iconic Winamp look. The eye reads the cap as
  "loudness recently happened here" — without it the display feels
  amnesiac.
- **Per-frame `*= 0.85` decays** (instead of `dt`-aware ones) make the
  visualization speed-dependent: change frame rate or run on a 120 Hz panel
  and the bars suddenly behave differently.
- **Treating the analyzer's normalized bands as already-perceptual.** vDSP
  output is linear magnitude. A 1 % magnitude is still ~ -40 dB and very
  audible; without dB scaling it looks like nothing.
- **Beat-additive height boost** on every bar. Pumps the floor and washes out
  detail. Boost color/luminance instead.

## Comparison with current implementation

Reading `BarsScene.swift`, `Bars.metal`, `vk_bars_process` in
`VisualizerKernels.cpp`:

| Aspect | Current | Canonical | Gap |
|---|---|---|---|
| Frequency mapping | None — each input band == one bar | Log rebinning with `f_min..f_max` | **Missing** |
| Magnitude scale | `pow(v, 0.7)` gamma | `20·log10` over `[dB_floor, dB_ceil]` | **Missing** |
| Perceptual tilt | Implicit in gamma only | Explicit `+3 dB/oct` slope | Missing |
| Attack | `τ = 60 ms` | `τ = 20 ms` | Too slow on rise |
| Release | `τ = 380 ms` | `τ = 300 ms` | Close (ok) |
| Smoothing dt-aware | Yes (`exp(-dt/τ)`) | Yes | OK |
| Peak cap | **Absent** | Per-bar with hold + fall | **Missing** |
| Beat handling | Additive `+beat * 0.18` on every band | Color flash only | Wrong shape |
| Beat envelope | `*= 0.85` per frame, frame-rate dependent | `dt`-aware | Wrong |
| Vertical layout | Centered/mirrored | Floor-anchored OR mirrored (both ok) | Stylistic |
| Color gradient | Palette by height + center | Vertical green→yellow→red OR palette + cap highlight | OK |
| Bar SDF / AA | Rounded box, fwidth-AA | Same | Good |
| Bar count switch | 24/32/48/64 — resets state | Same | Good |

## Concrete fix list

1. **`Vendor/VisualizerKernels/VisualizerKernels.cpp` — `vk_bars_process`:**
   Replace the gamma `pow(v, 0.7)` with the dB pipeline:
   `dB = 20 * log10(max(v, 1e-4))`, then
   `v01 = clamp((dB + 70) / 60, 0, 1)`. Inputs are already linear magnitudes.

2. **`Vendor/VisualizerKernels/VisualizerKernels.cpp` — add a new kernel
   `vk_bars_rebin`** (or do this in `BarsScene.swift`): take 64 linear input
   bands and `N_bars`, produce `N_bars` log-spaced values via:
   `f_lo, f_hi = 40 * (16000/40)^(k/N), 40 * (16000/40)^((k+1)/N)` →
   linear indices → `max` (or interpolate for narrow ranges).
   Add a `sampleRate` parameter (default 48000) so the mapping is correct.

3. **`Vendor/VisualizerKernels/VisualizerKernels.cpp` — `vk_bars_process`:**
   change `attack_tau` from `0.060` to `0.020` (20 ms) and `release_tau`
   from `0.380` to `0.300` (300 ms).

4. **`Vendor/VisualizerKernels/VisualizerKernels.cpp` — `vk_bars_process`:**
   remove the `beatLift` term (no additive height boost). Beat handling
   moves to color in the fragment shader.

5. **`Vendor/VisualizerKernels/VisualizerKernels.cpp` — extend the kernel**
   to also output a parallel array of **peak positions** with hold/fall
   logic (state grows from `count` to `2*count` plus `count` hold timers):
   constants `peak_hold = 0.5 s`, `peak_fall = 0.6 /s`.

6. **`AudioVisualizer/Infrastructure/Metal/Scenes/BarsScene.swift`:** allocate
   a second `MTLBuffer` for peak positions (`peaks[N_bars]`) and pass to the
   vertex shader. Increase the C++ state buffer to hold
   `[displayed | peaks | holdTimers]` per bar.

7. **`AudioVisualizer/Infrastructure/Metal/Shaders/Bars.metal` —
   `bars_vertex`:** stop centering bars vertically. Anchor at `y = -1`
   (floor) and grow up to `y = -1 + 2*h*0.96`. Mirror is a stylistic choice;
   the canonical Winamp look is **floor-anchored**.

8. **`Bars.metal` — add a peak cap pass:** issue 2× the instances (or render
   a second instanced draw) that draws a thin horizontal slab of height
   `~0.012` NDC at `y = -1 + 2*peak*0.96`.

9. **`Bars.metal` — `bars_fragment`:** replace the centered gradient with a
   vertical floor→tip gradient. Palette U from height: `palU = 0.15 + 0.7 *
   yLocal`. Add `beatFlash = uniforms.beatStrength * 0.15` to the value
   channel for ~80 ms after a beat (drive from `BarsScene` state).

10. **`BarsScene.swift`:** replace `self.beat *= 0.85` with a `dt`-aware
    decay: `self.beat *= exp(-dt / 0.080)` (80 ms envelope).

11. **`BarsScene.swift` — `update`:** the `n = min(spectrum.bands.count, barCount)`
    line is wrong once rebinning lands — `barCount` is independent of input
    count. Pass full `spectrum.bands.count` to the rebin kernel and write
    `barCount` outputs.

12. **Add a slope constant** in `vk_bars_process` (or before it):
    `slope_dB(k) = 3.0 * log2(f_center(k) / 1000)`, added to `dB(k)` before
    the floor clamp. Requires bar-center frequencies, which the rebin step
    already computes — pass them through.

## References

1. audioMotion-analyzer (MIT) —
   https://github.com/hvianna/audioMotion-analyzer
2. Web Audio AnalyserNode min/maxDecibels semantics —
   https://developer.mozilla.org/en-US/docs/Web/API/AnalyserNode/minDecibels
3. Winamp Classic Spectrum Analyzer (Mike Lynch) —
   https://winampheritage.com/visualization/classic-spectrum-analyzer/165966
4. foobar2000 `foo_vis_spectrum_analyzer` —
   https://github.com/stuerp/foo_vis_spectrum_analyzer
5. Octave-band analysis — FFT binning vs. filter banks —
   https://www.crysound.com/blog/octave-band-analysis-guide-fft-binning-vs-filter-bank-method/
6. WaveShop peak-decay model (hold + dB/s fall) —
   https://waveshop.sourceforge.net/Help/Options/Spectrum/Peak_decay.htm
7. Smoothing FFT data on log-frequency bins —
   https://lists.gnu.org/archive/html/help-octave/2015-07/msg00016.html
8. SRS "About FFT Spectrum Analyzers" application note —
   https://www.thinksrs.com/downloads/pdfs/applicationnotes/AboutFFTs.pdf
