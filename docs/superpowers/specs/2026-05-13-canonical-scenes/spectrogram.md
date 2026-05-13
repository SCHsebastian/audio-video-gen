# Canonical Spectrogram Scene — Design Spec

Status: design only — no implementation yet.
Targets: `AudioVisualizer/Infrastructure/Metal/Scenes/SpectrogramScene.swift` +
`AudioVisualizer/Infrastructure/Metal/Shaders/Spectrogram.metal`.

## Visual goal

A "proper" spectrogram is a **time-frequency heatmap** that looks like the
output of Sonic Visualiser, iZotope RX, Adobe Audition, Spek, or Audacity:
**time runs horizontally and scrolls right-to-left** (newest data appears at the
right edge), **frequency runs vertically on a logarithmic axis** (bass at the
bottom, treble at the top, roughly one octave per equal screen segment), and
**amplitude is encoded in a perceptually uniform colormap** (viridis / inferno
/ magma) after **dB compression with an ~80 dB dynamic range**. The result
should feel like a dense, continuously-flowing ribbon — quiet sections render
as a near-black background with a soft purple/blue haze, sustained tones show
as bright horizontal streaks, transients punch through as vertical needles,
and harmonic stacks (vocals, strings) are visible as evenly-spaced parallel
ridges.

Reference images (links — embed them mentally):

- Sonic Visualiser default spectrogram (heatmap colour scheme, log-Hz axis):
  https://www.sonicvisualiser.org/screenshots.html
- iZotope RX 11 spectrogram (black background, fiery hot palette):
  https://s3.amazonaws.com/izotopedownloads/docs/rx6/07-spectrogram-waveform-display/index.html
- Spek (viridis-like, dB-scaled, log-frequency):
  https://www.spek.cc/

## Inputs

Per the existing `VisualizerScene` protocol:

- `spectrum.bands: [Float]` — 64 linear-frequency FFT band magnitudes in
  `[0, 1]` (post-vDSP, post-normalization). Linear means bin `k` covers
  `[k * 24000/64, (k+1) * 24000/64]` Hz ≈ 375 Hz per bin.
- `waveform: [Float]` — 1024 PCM samples in `[-1, 1]` (unused by this scene).
- `beat: BeatEvent?` — optional kick marker (used only for an optional faint
  vertical white tick).
- `dt: Float` — seconds since previous frame (used for time-based scroll if we
  prefer a continuous variant over the per-frame variant).
- `SceneUniforms { time, aspect, rms, beatStrength }` plus the scene-local
  uniforms defined below.

Capture is 48 kHz, so the **Nyquist limit is 24 kHz** and the spectrum covers
linear `[0, 24 kHz]`. Audible content lives mostly in `[20 Hz, ~16 kHz]`.

## Algorithm — step by step

### 1. Storage: wide RGBA / R-channel history texture

Allocate one **`R16Float` 2D texture, `W = 1024` columns × `H = 256` rows**:

- Columns are **time**: one column == one analysis frame ≈ one display frame
  (the scene is driven at the display refresh, not the FFT hop, but visually
  that is indistinguishable for a real-time visualizer).
- Rows are **log-frequency bins**: row `0` == lowest displayed frequency
  (≈ 20 Hz), row `H-1` == Nyquist (≈ 24 kHz).
- Channel: a single `R16Float` is enough; the colormap lookup converts the
  scalar into RGB at sample time.

We deliberately store **log-frequency-mapped, dB-scaled, normalized magnitude
∈ [0, 1]** in the texture — not the raw linear-band magnitudes. All the
expensive math happens once per frame on the CPU (256 rows × cheap math) and
the shader becomes a single texture sample + palette lookup.

### 2. Per-frame CPU build of one column (`H = 256` rows)

```
Inputs:  bands[0..63] in [0, 1], linear over [0, 24 kHz]
Outputs: column[0..255] in [0, 1], log-frequency, dB-scaled, normalized
```

Constants:

```
F_MIN     = 20.0       // Hz — bottom of visible axis
F_MAX     = 24000.0    // Hz — Nyquist (top of visible axis)
H         = 256        // log-frequency rows
EPS       = 1e-6       // anti-log0 floor
DB_FLOOR  = -80.0      // dB at which the colormap clamps to 0
DB_CEIL   = 0.0        // dB at which the colormap clamps to 1
BAND_HZ   = 24000.0 / 64.0   // ≈ 375 Hz per linear FFT band
```

For each output row `k ∈ [0, H)`:

1. **Log-frequency for row k.** Equally-spaced octaves up the axis:

   ```
   f_k = F_MIN * (F_MAX / F_MIN) ^ (k / (H - 1))
       = 20 * 1200^(k/255)            // ≈ 10.23 octaves total
   ```

   (The brief's `20 * (24000/20)^(k/255)` is the same formula — both `F_MAX /
   F_MIN = 1200`.)

2. **Lookup into the linear bands array.** Find the fractional linear bin:

   ```
   bin_f = f_k / BAND_HZ              // ∈ [0, 64)
   bin_lo = floor(bin_f)
   bin_hi = min(bin_lo + 1, 63)
   t = bin_f - bin_lo
   mag = (1 - t) * bands[bin_lo] + t * bands[bin_hi]
   ```

   For `f_k < BAND_HZ` (the bottom ~3 rows) the same formula still produces a
   valid value; the bass detail will be coarse because we only have 64 linear
   bands, but the log mapping at least gives those low frequencies their share
   of screen real estate.

   Future upgrade path: when the FFT analyzer gains a finer linear band count
   (e.g. 1024 bins), only this lookup changes — the texture layout and shader
   stay the same.

3. **dB scaling.** Convert linear magnitude to dB and normalize to `[0, 1]`:

   ```
   dB     = 20 * log10(mag + EPS)
   v_norm = clamp((dB - DB_FLOOR) / (DB_CEIL - DB_FLOOR), 0, 1)
          = clamp((dB + 80) / 80, 0, 1)
   ```

   This is the librosa default — `amplitude_to_db` with `ref = 1.0`,
   `top_db = 80.0`, `amin = 1e-5`-ish.

4. **Optional perceptual gamma.** After normalization apply a mild `pow(v,
   0.8)` if the result feels too dark — empirically `0.8`–`1.0` keeps the
   image readable without crushing transients. Default: skip (rely on dB).

5. **Optional time smoothing.** A one-pole IIR per row to reduce shimmer:
   `column[k] = max(v_norm, prev_column[k] * 0.85)`. This is the canonical
   "peak hold with decay" used by RX and Spek and gives sustained notes a
   stable look without smearing transients.

### 3. Write strategy: ring-buffer texture, scroll in the shader

The CPU does **not** memmove the texture. Instead:

```
col = frameCount % W          // current write column (0..W-1)
texture.replace(region: MTLRegionMake2D(col, 0, 1, H),
                mipmapLevel: 0,
                withBytes: column,
                bytesPerRow: H * sizeof(Float16))
frameCount += 1
```

This writes **one column per frame**. The shader handles the visual scroll by
remapping `uv.x`:

```
// scene-local uniform
write_col_norm = (frameCount % W) / float(W)

// in fragment:
// We want uv.x = 0 to show the OLDEST column, uv.x = 1 the NEWEST (just-written).
// The newest column lives at write_col_norm - 1/W (mod 1).
float u_tex = fract(uv.x + write_col_norm)
```

Mathematically `fract(uv.x + write_col_norm)` rotates the texture so that the
write head sits at the right edge and history streams off the left edge — the
canonical waterfall scroll used by `spectro` (calebj0seph) and every web-audio
visualizer.

For the Y axis we sample directly: `v_tex = uv.y` (assuming `uv.y = 0` at
bottom and `1` at top). The texture is already log-spaced, so this is a
linear sample.

### 4. Color map (viridis default, inferno alt)

Sample the existing `paletteTexture` — but the palette must actually be
viridis or inferno, not the green/cyan ramp the bars scene happens to use. The
spec assumes the palette is a 1-D `256 × 1` RGBA texture; the colormap module
already exists, we just register a new entry.

**Viridis** (5 anchor stops, linearly interpolated in sRGB — the matplotlib
canonical points sampled at positions `0, 0.25, 0.5, 0.75, 1.0`):

| t    | R       | G       | B       |
| ---- | ------- | ------- | ------- |
| 0.00 | 0.26700 | 0.00487 | 0.32942 |
| 0.25 | 0.22006 | 0.34331 | 0.54941 |
| 0.50 | 0.12231 | 0.63315 | 0.53040 |
| 0.75 | 0.28892 | 0.75839 | 0.42843 |
| 1.00 | 0.99325 | 0.90616 | 0.14394 |

**Inferno** (alt, for "fiery RX-style" mode), same 5-point sampling:

| t    | R       | G       | B       |
| ---- | ------- | ------- | ------- |
| 0.00 | 0.00146 | 0.00047 | 0.01386 |
| 0.25 | 0.25849 | 0.03883 | 0.40624 |
| 0.50 | 0.57852 | 0.14837 | 0.40398 |
| 0.75 | 0.86509 | 0.31636 | 0.22667 |
| 1.00 | 0.98807 | 0.99836 | 0.64492 |

Lookup in the fragment shader:

```metal
float v = history.sample(s, float2(u_tex, v_tex)).r; // ∈ [0, 1]
float3 c = palette.sample(s, float2(v, 0.5)).rgb;
```

### 5. Y-axis: log-frequency mapping (already baked into the texture)

Because the column build (step 2) already remaps linear FFT bands onto a
log-frequency grid, the shader just samples `uv.y` directly. The display
mapping is:

```
f_display(y) = F_MIN * (F_MAX / F_MIN) ^ y        // y ∈ [0, 1]
              ≈ 20 * 1200^y                       // Hz
```

Per pixel-row of the **output** at height `Hp` pixels:

```
y_row = row_p / (Hp - 1)
f_row = 20 * 1200^y_row
```

### 6. Optional overlays

- **Pitch-class lines** (faint horizontal lines at musically meaningful Hz).
  Toggle behind a uniform `showPitchGrid: Bool`. Draw at A2, A3, A4, A5, A6
  (110, 220, 440, 880, 1760 Hz) — convert to y via `y = log(f/F_MIN) /
  log(F_MAX/F_MIN)` and add a faint white line ±1 px.
- **Beat tick.** When `beat != nil`, write the current column with an extra
  thin bright marker at the bottom 4 rows (sub-bass). It will scroll off
  naturally with the rest of the data.
- **Frequency labels.** Out of scope here — text rendering is a separate
  concern; if added later, render them as a static overlay layer (CoreText →
  texture once at build time).

## Critical numerical constants

| Constant     | Value     | Why                                                 |
| ------------ | --------- | --------------------------------------------------- |
| `W`          | 1024      | Time history width — ≈ 17 s at 60 fps               |
| `H`          | 256       | Log-frequency rows — ≈ 25 rows / octave, smooth     |
| `F_MIN`      | 20.0 Hz   | Bottom of audible band                              |
| `F_MAX`      | 24000.0   | Nyquist at 48 kHz capture                           |
| `BAND_HZ`    | 375.0     | 24 kHz / 64 linear FFT bands                        |
| `EPS`        | 1e-6      | Anti-log0                                           |
| `DB_FLOOR`   | -80.0 dB  | librosa default `top_db`                            |
| `DB_CEIL`    | 0.0 dB    | Reference                                           |
| `decay`      | 0.85      | Per-frame IIR for the "peak hold" smoothing         |
| `gamma`      | 0.8 – 1.0 | Post-norm tone curve (default 1.0 = none)           |
| Pixel format | R16Float  | Enough precision for `[0,1]` after dB normalization |

## Common pitfalls (these are the symptoms the current scene exhibits)

1. **Linear y-axis squashes bass.** With 64 linear bins covering `[0, 24
   kHz]`, the bottom octave (`20–40 Hz`) gets less than 1/600 of the screen.
   All the musical content lives in the bottom ~3 % of the image. Fix: log-Hz
   y-axis (step 2).
2. **No dB compression.** Raw `[0, 1]` magnitudes mean only the loudest peak
   colors are ever visible — quiet bands look like background. Fix: 20·log10
   + 80 dB normalization (step 2.3).
3. **Sqrt curve is not log.** `sqrt(uv.x)` (current shader) is not a
   logarithmic mapping; it under-emphasizes mid frequencies and over-
   emphasizes bass without ever exposing the high octaves cleanly.
4. **Accumulating instead of scrolling.** If the texture is not written
   ring-buffer-style, sustained content "wipes" the same row repeatedly,
   smearing into a wash. Fix: `col = frameCount % W` + shader fract scroll
   (step 3).
5. **Wrong scroll direction.** Most spectrogram readers expect time → right,
   newest on the right edge. The current shader uses Y for time (rows) which
   is the radar / waterfall convention, not the audio-visualizer
   convention.
6. **Wrong colormap.** A green ramp gives no contrast on bright peaks. Viridis
   / inferno are perceptually uniform and battle-tested for spectrograms.
7. **Wrong texture format.** A non-float format (`bgra8Unorm`) clamps to
   `[0, 1]` with only 8 bits of precision — the bottom 20 dB of the
   normalized output collapses into ≤ 50 codes. `R16Float` is the canonical
   choice.
8. **Texture filtering.** `filter::linear` is fine **across columns** (smooth
   time) but produces a soft, blurry frequency axis. Consider
   `mag::linear, min::linear` for x and `mag::nearest` for y, or just keep
   linear and accept the slight smoothing — most reference renderers do.

## Comparison with current implementation

Read of `SpectrogramScene.swift` + `Spectrogram.metal`:

| Aspect            | Current                                       | Canonical                                      |
| ----------------- | --------------------------------------------- | ---------------------------------------------- |
| Texture size      | `bandCount × historyRows` = `64 × 256`        | `W × H` = `1024 × 256`                         |
| Pixel format      | `r32Float`                                    | `r16Float` (half the memory, plenty of range)  |
| Time axis         | **Vertical** (rows = time)                    | **Horizontal** (columns = time)                |
| Frequency axis    | **Horizontal**, `sqrt(uv.x)`                  | **Vertical**, log-Hz, baked into texture       |
| Frequency mapping | `sqrt` on display only                        | Proper `f_k = F_MIN·(F_MAX/F_MIN)^(k/(H−1))`   |
| dB scaling        | None — raw `[0,1]` magnitude, `pow(0.55)`     | `20·log10 + EPS`, normalize over `[-80, 0]`    |
| Ring buffer       | Per-row, vertical (`writeIndex` rows)         | Per-column, horizontal (`frameCount % W`)      |
| Scroll formula    | `(writeIndex - 1 - age + 2·rows) % rows`      | `fract(uv.x + write_col_norm)`                 |
| Palette           | Whatever palette texture is currently bound   | Viridis (default) + inferno (alt)              |
| Smoothing         | None on CPU; sample is linear                 | 1-pole IIR with `decay = 0.85` per row         |
| Beat / overlay    | Subtle 4 % scan line                          | Optional pitch grid, optional beat tick        |

In short: **every coordinate is wrong**. The scene currently behaves like a
radar waterfall with a sqrt-stretched x-axis, no dB, and a vertical time axis.
Visually it looks more like a frequency-bar scene that smears upward over
time than a spectrogram.

## Concrete fix list (numbered, plan-ready)

1. **Resize history texture to `1024 × 256` and pixel format `R16Float`.**
   Update `bandCount`/`historyRows` symbols → `W`/`H`. Zero-fill at build.
2. **Swap axes.** Make columns = time, rows = log-frequency. The CPU now
   writes a *column* (height `H`) per frame, not a row.
3. **Add CPU column build.** Implement `buildColumn(bands:) -> [Float16]`
   that does steps 2.1–2.4: log-Hz remap of 64 linear bands → 256 rows, then
   `20·log10`, then normalize over `[-80, 0]`.
4. **Add per-row 1-pole IIR.** Keep a `previousColumn: [Float]` array;
   `column[k] = max(new, prev[k] * 0.85)`. Reset on scene rebuild.
5. **Ring-buffer write by column.** `col = frameCount % W; replace(region:
   MTLRegionMake2D(col, 0, 1, H), …); frameCount += 1`.
6. **Rewrite the fragment shader.** Sample `u_tex = fract(uv.x +
   writeColNorm)`, `v_tex = uv.y`, look up the scalar, look it up again in
   the palette. Drop the `sqrt`, drop the `pow(0.55)`, drop the scan line.
7. **Register a viridis palette and a inferno palette** in the existing
   palette module (5 stops each — values in the tables above) and wire the
   spectrogram scene to viridis by default.
8. **Add scene-local uniforms.** `struct SpecUniforms { float aspect; uint
   W; uint H; float writeColNorm; uint showPitchGrid; }` — passed via
   `setFragmentBytes`.
9. **(Optional) Pitch-grid overlay.** Behind `showPitchGrid`, draw faint
   horizontal lines in the fragment shader at `y = log(f/F_MIN) /
   log(F_MAX/F_MIN)` for A2…A6.
10. **(Optional) Beat tick.** On `beat != nil`, override the bottom 4 rows of
    the freshly-written column with `1.0` before upload.

## References

- Sonic Visualiser — screenshots and feature tour (log-Hz spectrogram, dB
  legend, colour shading): https://www.sonicvisualiser.org/screenshots.html
- iZotope RX — Spectrogram/Waveform display, dynamic-range slider, color
  presets: https://s3.amazonaws.com/izotopedownloads/docs/rx6/07-spectrogram-waveform-display/index.html
- librosa `amplitude_to_db` — canonical 20·log10 + `top_db = 80` + `amin =
  1e-5`: https://librosa.org/doc/main/generated/librosa.amplitude_to_db.html
- `spectro` (calebj0seph) "making of" — ring-buffer column write + `mod 1.0`
  shader scroll: https://github.com/calebj0seph/spectro/blob/master/docs/making-of.md
- Caleb Gannon — Three.js + GLSL spectrogram, copyWithin + jet LUT:
  https://calebgannon.com/2021/01/09/spectrogram-with-three-js-and-glsl-shaders/
- Matplotlib viridis source — RGB control points and design rationale:
  https://bids.github.io/colormap/
- AudioLabs Erlangen — log-frequency spectrogram derivation `Y = H·X`:
  https://www.audiolabs-erlangen.de/resources/MIR/FMP/C3/C3S1_SpecLogFreq-Chromagram.html
- D.P.W. Ellis (Columbia) — constant-Q vs conventional spectrogram, octave
  spacing: https://www.ee.columbia.edu/~dpwe/resources/matlab/sgram/
