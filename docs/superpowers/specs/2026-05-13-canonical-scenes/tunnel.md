# Tunnel — canonical demoscene flying-through-a-tunnel visualizer

Status: design spec (rewrite target). Owner: Tunnel scene.

## Visual goal

A first-person flight down an infinite cylindrical tunnel: the camera barrels
forward through a textured pipe, rings of pattern (checker / stripes / palette
bands) streaming past, the inner wall rotating slowly, the perspective pulled
toward a vanishing point at screen center. The look is **Future Crew "Second
Reality" (1993)** crossed with **iq's Shadertoy tunnels** — flat-shaded,
high-contrast, palette-cycled, and obviously *2D-trick* rather than expensive
3D. Bass drives twist and warp, RMS drives forward speed, beats fire a radial
shockwave + palette flash, and high-frequency content adds a fine surface
ripple.

References:
- iq "Tunnel" article (the canonical 2D trick): https://iquilezles.org/articles/tunnel/
- iq Shadertoy "Tunnel" with derivative-based AA: https://www.shadertoy.com/view/Ms2SWW
- demoscene tunnel history (Future Crew, table-based): https://carette.xyz/posts/the_tunnel_effect_demoscene/

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

Derived bands for this scene (computed on CPU each frame, low-pass smoothed):
- `bass`   = mean of bands `[0..4]`        (sub + low)
- `mid`    = mean of bands `[8..24]`
- `treble` = mean of bands `[40..63]`

Smooth each with `x += (target - x) * (1 - exp(-dt / tau))`, tau ≈ 0.10 s for
bass/mid, 0.04 s for treble (snappier).

## Algorithm — the 2D tunnel trick

### Step 1 — fragment coords to centered, aspect-corrected uv

```
vec2 p = in.uv;            // already in [-1, 1], full-screen quad
p.x *= aspect;             // square pixels
```

### Step 2 — camera roll and sway

A slow rotation of `(p.x, p.y)` sells the "flying with a slight banked turn"
feel. The roll is itself audio-coupled so heavy bass rocks the camera:

```
float roll = time * 0.10
           + bass * 0.50 * sin(time * 0.30)
           + 0.05 * sin(time * 0.7);     // gentle idle sway
mat2 R = mat2(cos(roll), -sin(roll),
              sin(roll),  cos(roll));
p = R * p;
```

### Step 3 — polar coordinates

```
float r = length(p);
float a = atan2(p.y, p.x);             // [-pi, pi]
```

### Step 4 — the depth trick: v = 1/r

The whole effect rests on the fact that for a viewer at the origin looking down
a cylinder of radius `R`, the projection of a wall point at depth `z` lands at
screen radius `r = R / z`. Inverting: **`z = R / r`**, i.e. `1/r` *is* depth
(up to a constant). So:

```
float K_DEPTH = 0.60;                   // tunnel radius constant
float depth  = K_DEPTH / max(r, 1e-3);  // z along the tunnel
```

The `max(r, 1e-3)` guard is non-negotiable — at the screen center `r = 0` and
`1/r` diverges, blowing out depth and causing texture aliasing/NaNs (see
pitfalls below).

### Step 5 — tunnel coordinates (u, v)

```
float SPEED = 0.35;
float u = a / 3.14159265;               // angle in [-1, 1]; wraps cleanly
float v = depth + time * (SPEED + rms * 2.5);  // axial position, scrolls
```

This `(u, v)` is the natural surface parametrization of the cylinder. Now we
sample a 2D pattern in `(u, v)`.

### Step 6 — twist (audio-coupled spiral)

Pure `u = a/pi` gives straight axial stripes. Adding a depth-dependent twist
makes the rings spiral, and the twist amount is the most "musical" knob —
push it with bass:

```
float TWIST_BASE  = 0.40;
float TWIST_AUDIO = 1.20;
float twist = TWIST_BASE + TWIST_AUDIO * bass;
u += twist * sin(v * 0.7);              // sinusoidal swirl along depth
```

(For a tighter helix swap `sin(v*0.7)` for `v * 0.25` — a linear shear gives a
constant-pitch screw.)

### Step 7 — surface pattern

Two options; we use **checkerboard** as the default because it sells depth
hardest:

```
float N_ANG = 8.0;                      // 8 angular cells per turn
float N_DEP = 4.0;                      // 4 depth bands per unit
vec2 cell = vec2(u * N_ANG * 0.5, v * N_DEP);
vec2 g    = fract(cell) - 0.5;          // local cell coord in [-0.5, 0.5]
float chk = step(0.0, g.x * g.y);       // hard checkerboard 0/1
```

**Anti-aliasing the checker.** A hard `step` aliases viciously near the
vanishing point (where cells shrink to sub-pixel). Use derivative-based
smoothstep:

```
vec2 fw = fwidth(cell);                 // pixel footprint in cell space
vec2 e  = smoothstep(0.5 - fw, 0.5 + fw, abs(g));
float chkAA = 1.0 - (e.x * (1.0 - e.y) + e.y * (1.0 - e.x));
```

Alternatively (and what iq's article documents): sample the angle's gradient
through `abs(u)` to avoid the `atan2` `±π` discontinuity:

```
float aSym = atan2(p.y, abs(p.x));      // symmetric, no -pi/+pi seam
vec2 uvR   = vec2(v, aSym / 3.14159265);
// pass dFdx(uvR), dFdy(uvR) to a textureGrad sample
```

### Step 8 — palette mapping

We already have a 1D palette texture in the renderer. Drive the palette index
off `(v, chkAA)` so the rings cycle colour as they fly past:

```
float palU = fract(v * 0.25 + rms * 0.30);
float shade = mix(0.35, 1.00, chkAA);   // dark/light checker
vec4  col   = palette.sample(s, vec2(palU, 0.5)) * shade;
```

Add a treble-driven hue shimmer by perturbing `palU` with high bands:

```
palU += treble * 0.10 * sin(a * 6.0 + time * 5.0);
```

### Step 9 — depth fog

Without fog the tunnel looks flat — depth pulled into the centre but with no
falloff, the vanishing point ends up brighter than the foreground. Two
equivalent options:

```
// Option A: exponential
float FOG_DENSITY = 0.15;
float fog = exp(-depth * FOG_DENSITY);

// Option B: rational (cheaper, also fine)
float fog = 1.0 / (1.0 + depth * 0.20);
```

Multiply colour by fog, and *add* a faint vanishing-point glow back in so the
centre doesn't go to absolute black:

```
col.rgb *= fog;
col.rgb += vec3(0.04, 0.05, 0.08) * smoothstep(0.30, 0.00, r);
```

### Step 10 — beat radial pulse

On beat, fire an outward ring by perturbing `r` (or `v`) with a decaying sine
in `r`:

```
float pulse = beatStrength * exp(-3.0 * abs(r - 0.5 * (1.0 - beatAge)));
col.rgb    += pulse * vec3(1.0, 0.7, 0.9);
```

(`beatAge` ramps 0→1 over ~0.35 s after each beat; the shockwave grows
outward.) A simpler version uses just a multiplicative flash:
`col.rgb *= 1.0 + 0.30 * beatStrength`.

### Step 11 — vignette

A cheap radial vignette so the corners fall to black:

```
float vign = smoothstep(1.6, 0.4, length(in.uv));
col.rgb *= vign;
```

### Step 12 — output

```
return float4(col.rgb, 1.0);
```

## Critical numerical constants

| Constant         | Value         | Why                                                          |
|------------------|---------------|--------------------------------------------------------------|
| `K_DEPTH`        | 0.60          | tunnel radius (smaller → tunnel feels narrower)              |
| `EPS_R`          | 1e-3          | floor on `r` to avoid `1/0` singularity at screen centre     |
| `SPEED`          | 0.35          | base forward velocity (texels/sec in `v`)                    |
| `RMS_SPEED_GAIN` | 2.5           | how hard loud audio accelerates forward motion               |
| `TWIST_BASE`     | 0.40          | idle twist amount                                            |
| `TWIST_AUDIO`    | 1.20          | bass coupling into twist                                     |
| `N_ANG`          | 8             | angular checker cells per full turn (must be even)           |
| `N_DEP`          | 4             | depth checker cells per unit `v`                             |
| `FOG_DENSITY`    | 0.15          | exponential fog rate; 0 = no depth feel                      |
| `ROLL_SPEED`     | 0.10 rad/s    | idle camera roll                                             |
| `tau_bass`       | 0.10 s        | low-pass on bass envelope                                    |
| `tau_treble`     | 0.04 s        | low-pass on treble envelope (snappier)                       |

## Common pitfalls

1. **Singularity at screen centre.** `1/r` at `r = 0` is `+inf`. Always
   `depth = K_DEPTH / max(r, EPS_R)`. Symptoms: a single black/white pixel
   that flickers; aliasing rings around the centre; NaN on some GPUs.

2. **`atan2` discontinuity at `x < 0, y = 0`.** Jumps from `+π` to `−π` —
   makes a hard seam along the negative-x axis when sampling the pattern.
   Fix per iq: pass *gradients* computed from `atan2(y, |x|)` to
   `textureGrad`, *not* derivatives of the raw `atan2`. With analytic patterns
   (checker) use `fwidth(cell)` from the *cell-space* coords, not screen
   space, and the seam disappears.

3. **No depth fog → no depth.** A flat-shaded checker that just streams
   outward looks like a 2D zoom, not a tunnel. The exponential-fog darkening
   into the centre is what creates the *vanishing point* illusion.

4. **Checker cells alias at the vanishing point.** Without derivative AA the
   centre turns into a moiré soup. `fwidth(cell)` based smoothstep is cheap
   and fixes it in one line.

5. **No audio coupling.** A constantly-rotating spiral with no beat or bass
   response feels like a screensaver. The whole point of an audio-reactive
   tunnel is that bass *warps the geometry* and beats *fire shockwaves*.

6. **`time * direction` only.** Negating time flips "into" vs "out of" the
   tunnel but doesn't add visual interest. Tie speed to `rms` so loud
   passages physically push you forward.

7. **Linear palette band off `intensity`.** Sampling the palette by an
   arbitrary scalar that depends on `r` produces concentric colour rings, not
   axial colour-cycle. The palette should advance with **v** (depth), so
   colour appears to *fly past you*, not radiate from the centre.

8. **Square checker stretched by aspect.** If you don't `p.x *= aspect`
   before going polar, the tunnel becomes an ellipse and the cells distort
   asymmetrically.

9. **Twist that doesn't depend on `v`.** Multiplying `a` by a constant just
   rotates the whole image. The spiral effect requires the twist to be a
   function of depth (`u += twist * sin(v*…)` or `u += twist * v`).

## Comparison with current implementation

Current files:
- `/Users/sebastiancardonahenao/development/audio-video-gen/.claude/worktrees/youthful-almeida-53ac93/AudioVisualizer/Infrastructure/Metal/Shaders/Tunnel.metal`
- `/Users/sebastiancardonahenao/development/audio-video-gen/.claude/worktrees/youthful-almeida-53ac93/AudioVisualizer/Infrastructure/Metal/Scenes/TunnelScene.swift`

What the current shader does (lines 33-53 of `Tunnel.metal`):

- Computes `r`, `a` from aspect-corrected `p`. ✅
- Defines `depth = u.depth / max(r, 0.001)`. ✅ Has the singularity guard.
- Defines `twist = a/π + 0.5` and `band = fract(depth - time * (0.35 + rms*2.5))`. ✅ Speed couples to rms.
- Renders **rings only** via two ring kernels: a smoothstep band of width `w`
  and a gaussian highlight. There is **no checkerboard** — angular variation
  is added only as `swirl = 0.5 + 0.5 sin(twist * 6 + time)` mixed in at 10%.
- Vignette + beat multiplicative pulse.
- Samples palette by `intensity` (a scalar that depends on `r`), so colour
  rings are concentric — opposite of "colour flying past".

Gaps versus the canonical tunnel:

| Canonical feature                               | Current state                          |
|-------------------------------------------------|----------------------------------------|
| 2D trick `(u, v) = (a/π, 1/r + t)`              | partial — `u` unused for sampling      |
| Surface pattern in `(u, v)`                     | missing — only depth rings             |
| Depth-coupled twist (spiral)                    | weak — additive swirl, not in `u`      |
| Bass → twist amount                             | missing                                |
| RMS → forward speed                             | present                                |
| Beat → radial shockwave                         | only flat multiplicative pulse         |
| Treble → high-freq surface ripple               | missing                                |
| Derivative-based AA on pattern                  | missing — uses fixed-width smoothstep  |
| Distance fog (`exp(-depth * k)`)                | missing — only screen-space vignette   |
| Palette advances with depth `v`                 | missing — palette samples `intensity`  |
| Camera roll / sway                              | missing                                |
| Vanishing-point glow                            | missing                                |
| `atan2` seam handling                           | not addressed                          |

## Concrete fix list

1. **Add CPU-side audio derivatives** in `TunnelScene.swift`: compute `bass`,
   `mid`, `treble` from `spectrum.bands` and low-pass smooth them; pass into
   uniforms alongside `rms`, `beat`.

2. **Add a camera-roll term** in the shader. Rotate `p` by
   `roll = 0.10 * time + 0.50 * bass * sin(time * 0.30)` before going polar.

3. **Switch from ring-only to (u, v) cylinder mapping.** Compute `u = a/π`,
   `v = K_DEPTH / max(r, 1e-3) + time * (SPEED + rms * 2.5)`.

4. **Add depth-coupled twist** to `u`:
   `u += (TWIST_BASE + TWIST_AUDIO * bass) * sin(v * 0.7)`.

5. **Render a checkerboard pattern** in `(u, v)` with
   `N_ANG = 8`, `N_DEP = 4`, and derivative-based AA via `fwidth(cell)`.

6. **Use the palette as colour-along-depth**: `palU = fract(v * 0.25 + rms * 0.30)`;
   shade by checker (`mix(0.35, 1.0, chkAA)`); add treble hue jitter via
   `palU += treble * 0.10 * sin(a*6 + time*5)`.

7. **Apply exponential fog** `col.rgb *= exp(-depth * 0.15)` and add a small
   constant glow inside `r < 0.3` so the centre isn't pure black.

8. **Replace flat beat pulse with a radial shockwave**: track `beatAge` on
   CPU (resets to 0 on beat, increases by `dt / 0.35` to a max of 1), pass
   in; add `pulse = beatStrength * exp(-3 * abs(r - 0.5 * (1 - beatAge)))`
   to colour.

9. **Add a high-freq surface ripple** driven by treble:
   `v += treble * 0.04 * sin(a * 12.0 + time * 8.0)` *before* depth-fog (so
   the rings wobble axially when hats/cymbals hit).

10. **Tighten randomization** in `TunnelScene.randomize()`: randomize
    `K_DEPTH` ∈ [0.45, 0.85], `N_ANG` ∈ {6, 8, 12}, `N_DEP` ∈ {3, 4, 6},
    `direction` ∈ {-1, +1}, leaving twist/speed audio-driven so they remain
    musical.

## References

1. Inigo Quilez — "Tunnel" article (canonical 2D trick + derivative AA):
   https://iquilezles.org/articles/tunnel/
2. Inigo Quilez — "Plane deformations" (the broader family `u=f(x,y)`):
   https://iquilezles.org/articles/deform/
3. iq Shadertoy "Tunnel" (reference implementation with `textureGrad`):
   https://www.shadertoy.com/view/Ms2SWW
4. Demoscene tunnel history (Future Crew, pre-computed LUT era):
   https://carette.xyz/posts/the_tunnel_effect_demoscene/
5. Shadertoy "Tunnel Effect Shader" (community variant):
   https://www.shadertoy.com/view/4djBRm
6. Inspirnathan — ray-marching tunnels primer:
   https://inspirnathan.com/posts/52-shadertoy-tutorial-part-6/
7. iq — raymarching distance fields (for the SDF-tunnel variant
   `p.xy *= rot(p.z * 0.3)`):
   https://iquilezles.org/articles/raymarchingdf/
