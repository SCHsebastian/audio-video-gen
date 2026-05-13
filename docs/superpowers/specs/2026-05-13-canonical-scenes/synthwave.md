# Synthwave / Outrun Horizon — Canonical Spec

> Status: research + retrofit brief for `SynthwaveScene` / `Synthwave.metal`.
> Authoring date: 2026-05-13. Targets macOS 14.2 Metal pipeline already in
> place (full-screen quad + `setFragmentBytes` uniforms, palette texture).

## 1. Visual goal

A first-person Outrun horizon: a flat **neon-cyan/magenta grid floor**
disappearing into a **pink-to-purple sunset sky**, with a **half-disc sun**
sliced by horizontal scanline cutouts on the horizon line, optional
**dark mountain silhouettes**, and **stars** in the upper sky. The grid
**scrolls toward the camera** and **wobbles to the bass**; the sun's glow
and global luma **pulse on beat**. The viewer should immediately think
Kavinsky *Nightcall*, The Midnight *Endless Summer*, or any Mitch Murder
album cover. Not "a grid with a circle on it" — the gestalt is *flat
horizon + scanline sun + perspective vanishing point at the centre*.

Reference shaders (Shadertoy IDs):
- `MslfRn` — *Synthwave Shader [VIP2017]* (canonical sun + grid)
- `WljfRc` — *Retro synthwave*
- `NsScWt` — *Synthwave grid landscape* (mountains + grid)
- `dt2SDt` — *Synthwave grid* (minimalist reference)
- `tsScRK` — *another synthwave sunset thing*

## 2. Inputs (already wired)

| Name | Type | Source | Use |
|---|---|---|---|
| `time` | Float | accumulating dt | grid scroll, scanline drift, star twinkle |
| `aspect` | Float | viewport w/h | NDC.x correction |
| `rms` | Float | `SpectrumFrame.rms` | sun rim brightness, global luma pulse |
| `bass` | Float | smoothed `spectrum.bands[0..5].mean()` | grid scroll boost, floor wobble |
| `beatStrength` | Float | `BeatEvent.strength`, decayed | sun flash, scanline pop |
| `palette` | `texture2d<float>` | `paletteTexture` (1×N) | colour theming |

The fragment shader receives `ndc ∈ [-1,1]²` from the existing 6-vertex
full-screen quad. **No mesh, no compute.**

## 3. Algorithm (per fragment)

### 3.1 Camera ray

```
uv      = ndc                    // [-1,1]²
uv.x   *= aspect                 // correct for non-square viewports
pitch   = 0.18 + bass*0.04       // horizon offset from screen centre
ray     = normalize(vec3(uv.x, uv.y + pitch, -1.0))
```

`pitch > 0` puts the horizon **below** screen centre, giving more sky
than floor — the canonical Outrun composition. Bass adds a tiny extra
sag so the world breathes.

`isFloor = ray.y < 0`. Below the horizon, do floor; above, do sky/sun.

### 3.2 Sky gradient (when `!isFloor`)

Sample three palette taps and lerp by `t = clamp(ray.y * 1.4, 0, 1)`:

```
top   = palette(0.05)    // deep purple   ~#1A0033
mid   = palette(0.40)    // violet        ~#5A1A6E
warm  = palette(0.78)    // hot magenta   ~#FF3D8A
sky   = mix(warm, mix(mid, top, t), t)
```

The double `mix` keeps the warm horizon band thin (most of the sky is
mid→top). At `t < 0.30` you are within ~12% of the horizon — skip stars
there to avoid putting stars *behind* the sun.

**Stars** (only when `t > 0.30`):

```
g  = floor(uv * 9.0)
n  = fract(sin(dot(g, vec2(127.1, 311.7))) * 43758.5453)   // hash
if (n > 0.985)  // ~1.5% of cells
    twinkle = 0.5 + 0.5*sin(time*(n*6) + n*30)
    sky += vec3(1) * twinkle * (t - 0.30) * 0.55
```

### 3.3 Sun (drawn in screen space, anchored to horizon)

Horizon screen-y: where `ray.y == 0`, which solves to `ndc.y = -pitch`.
Place the sun centre **just above** that line so the lower scanlines
clip into the floor naturally:

```
sunC  = vec2(0.0, -pitch + 0.05)
sunR  = 0.32                     // ~screen-height units (NDC)
d     = length(vec2(uv.x, ndc.y) - sunC)
```

Inside the disc (`d < sunR + 0.06`):

**Body gradient** — yellow/orange at top, magenta at bottom:

```
yIn  = clamp((ndc.y - sunC.y) / sunR, 0, 1)      // 0 = horizon, 1 = top
body = mix(palette(0.72)/*sunWarm*/,
           palette(0.95)/*sunHot */,
           smoothstep(0, 1, yIn))
```

**Horizontal scanline cutouts** — bands shrink and become more open as
they approach the horizon (the *Miami-Vice taper*):

```
slits = 1.0
if (yIn < 0.70):
    b    = yIn / 0.70                            // 0 at horizon, 1 at top of slit zone
    freq = mix(6.0, 16.0, b)                     // few thick bands → many thin
    duty = mix(0.28, 0.55, b)                    // open near horizon, tight up top
    slits = step(duty, fract(b*freq + 0.5))
    slits *= step(0.0, b)                        // safety
```

`step(duty, fract(...))` is the canonical scanline cutter — yields 0
where the band is "on" (eats the sun) and 1 where it's "off" (sun
visible). Drift the bands downward over time by adding `-time*0.30` to
the `fract()` argument for the *vinyl-roll* effect.

**Anti-aliased disc edge**:

```
aa   = fwidth(d) + 0.001
disc = 1 - smoothstep(sunR - aa, sunR + aa, d)
col  = mix(col, body, disc * slits)
```

**Halo / glow** — soft falloff outside the disc, modulated by rms +
beat:

```
halo = exp(-max(d - sunR, 0) / 0.10)
col += sunHot * halo * (0.18 + 0.40*rms + 0.30*beatStrength)
```

### 3.4 Mountains (optional, sit between sun and floor)

Pure 2D in screen space using 1D fbm noise on `uv.x`:

```
// hash + 1D value noise
hash(x)   = fract(sin(x*12.9898) * 43758.5453)
noise1(x) = mix(hash(floor(x)), hash(floor(x)+1), smoothstep(0,1,fract(x)))
fbm(x)    = 0.50*noise1(x) + 0.25*noise1(x*2) + 0.125*noise1(x*4)

mtnY    = -pitch + 0.05 + 0.18 * fbm(uv.x*2.5 + 7.0)   // peaks above horizon
mtnMask = smoothstep(mtnY + 0.005, mtnY - 0.005, ndc.y)
col     = mix(col, mountainCol, mtnMask)
```

Render mountains **only above the horizon** (`!isFloor`), after sun, so
they overlap the sun's bottom slits like silhouettes. `mountainCol`
should be the darkest palette tap (≈ `palette(0.00)`).

### 3.5 Grid floor (when `isFloor`)

The crux. **Ray-plane intersection, never 2D screen-space** — otherwise
you do not get a vanishing point.

```
t   = -1.0 / ray.y                  // intersect y = -1 (camera height 1)
wx  = ray.x * t
wz  = ray.z * t                     // ≤ 0 (forward = -z)
```

`t = (h - O.y) / D.y` with origin at `(0,0,0)` and plane `y = -1` gives
`t = -1 / D.y`. Valid because `ray.y < 0` ⇒ `t > 0`.

**Scrolling**: bias `wz` by time × speed. Speed = base + bass:

```
scroll = time * (1.2 + bass*2.4)
gx     = wx
gz     = wz + scroll
```

**Audio-reactive height wobble** (subtle — DO NOT raymarch, just bias
the line mask by a sinusoid evaluated at the *grid* coord):

```
wobble = bass * 0.10 * sin(gz*0.5 + time*1.5)
gx    += wobble * 0.3
gz    += wobble
```

(Visually: the lines ripple toward camera on bass. Cheaper than a real
displaced plane and indistinguishable at speed.)

**Filtered grid line mask** (Evan Wallace / Inigo Quilez idiom):

```
filteredGrid(coord, spacing, thickness):
    c = fmod(coord + 1000, spacing)
    d = min(c, spacing - c)            // dist to nearest line
    w = fwidth(coord)                  // per-pixel rate of change
    return smoothstep(thickness + w, thickness - w, d)

lineX = filteredGrid(gx, 1.0, 0.040)
lineZ = filteredGrid(gz, 1.0, 0.040)
grid  = max(lineX, lineZ)
```

`fwidth(coord)` widens the line in screen space as the world coord
changes faster per pixel (= further away). This is the whole reason
distant lines fade smoothly instead of moiréing. **Do not omit.**

**Distance fade** (fog):

```
dist     = abs(t)
fade     = exp(-dist * 0.06)               // exponential fog
closeness= 1 - clamp(dist * 0.025, 0, 1)
floorBase= mix(floorDeep, floorMid, closeness)
col      = mix(floorBase, lineCol, grid * fade)
```

**Neon bloom** (cheap glow without changing line sharpness):

```
bloom = smoothstep(0.15, 0.0,
                   min(min(fract(gx), 1-fract(gx)),
                       min(fract(gz), 1-fract(gz))))
col  += lineCol * bloom * 0.18 * fade
```

**Horizon haze** — blend last 18% of floor (just below horizon) into
the sky's warm band so the grid never has a hard horizon line:

```
horizonFade = smoothstep(0.0, 0.18, -ray.y)
col         = mix(skyWarm, col, horizonFade)
```

### 3.6 Beat flash

After all compositing, add a global pulse:

```
col += vec3(0.06, 0.02, 0.10) * beatStrength
```

Tinted toward magenta so it reads as "the sun pulsed", not "the
exposure changed".

## 4. Critical numerical constants

| Symbol | Value | What it controls | Tune if… |
|---|---|---|---|
| `pitch` | 0.18 (+0.04·bass) | horizon below screen centre | want more/less sky |
| `sunR` | 0.32 NDC | sun radius | sun feels small/huge |
| `sunC.y` | `-pitch + 0.05` | sun vertical anchor | sun crosses below horizon |
| slit `freq` | 6 → 16 | scanline density top→bottom | bands feel wrong cadence |
| slit `duty` | 0.28 → 0.55 | open/closed band ratio | bands too thick/thin |
| slit drift | -0.30/s | vertical scroll of bands | bands static or flickering |
| grid `spacing` | 1.0 world unit | line cadence | grid too dense / sparse |
| grid `thickness` | 0.040 | half-width of line in world | lines fat / hair-thin |
| `scroll` base | 1.2 u/s | floor speed at rest | floor too slow / vomity |
| `scroll` bass gain | 2.4 | bass-driven speed-up | feels too jumpy / dead |
| fog `falloff` | 0.06 | `exp(-d·k)` | horizon too clear / muddy |
| `closeness` clip | 0.025 | floor base lerp range | gradient too sudden |
| star density | `n > 0.985` | ~1.5% of grid cells | too many / too few stars |
| star skip band | `t > 0.30` | no stars near sun | stars in front of sun |
| beat flash | `0.06,0.02,0.10` | tint of pulse | flash reads wrong colour |

## 5. Common pitfalls

1. **Drawing the grid in 2D screen-space.** Using `floor(uv * N)` gives
   uniform squares with no vanishing point — reads as "graph paper",
   not Outrun. The whole gestalt fails. *Always* ray-plane intersect.
2. **No `fwidth` AA on the grid.** Distant lines moiré into noise; once
   `spacing` is smaller than a screen pixel you get speckle. Filtered
   grid using `smoothstep(thickness+w, thickness-w, d)` is non-negotiable.
3. **Sun without horizontal scanlines.** A plain semicircle reads as
   *sunset photo*, not *synthwave*. The cutouts are the genre signature.
4. **Sun centred on the horizon line exactly.** Lower scanlines clip
   into the floor and dim weirdly. Bias `sunC.y` up by ~0.05 so the
   bottom band sits just above the horizon.
5. **No fog/distance fade.** Grid extends to infinity, the horizon line
   becomes a hard razor edge, the eye can't find a vanishing point.
   Exponential fog (`exp(-d·k)`) is the standard.
6. **Forward scroll using `ray.y` instead of `ray.z`.** A common bug:
   author intersects, then scrolls by `t` instead of `wz`. Causes the
   lines to rubber-band sideways at the horizon. Always scroll `wz`.
7. **Bass coupled directly (not smoothed) to scroll speed.** Single
   loud kick → epileptic strobing. Smooth bass with α ≈ 0.10
   (already done in `SynthwaveScene.update`).
8. **Wobble applied as a vertical offset to `y_plane`.** Mathematically
   means re-solving the ray-plane intersection each pixel. Equivalent
   visual result by offsetting `gx`/`gz` after the solve — much cheaper.
9. **Mountains drawn after the floor instead of in the sky branch.**
   Result: mountains "in front of" the grid — wrong depth ordering.
   They are silhouettes *above the horizon*.
10. **Star hash function that scales with `time`.** Stars drift across
    the sky. Hash only spatial cell index; modulate brightness with time.

## 6. Comparison with current implementation

Read on disk:
- `/Users/sebastiancardonahenao/development/audio-video-gen/.claude/worktrees/youthful-almeida-53ac93/AudioVisualizer/Infrastructure/Metal/Scenes/SynthwaveScene.swift`
- `/Users/sebastiancardonahenao/development/audio-video-gen/.claude/worktrees/youthful-almeida-53ac93/AudioVisualizer/Infrastructure/Metal/Shaders/Synthwave.metal`

### What is already correct

- Ray construction matches §3.1 exactly (NDC, aspect, `pitch + bass·0.04`).
- Ray-plane intersection at `y = -1` via `t = -1/ray.y` (§3.5) — present
  and correct (`Synthwave.metal:125`).
- `filteredGrid` helper uses `fwidth` AA (`Synthwave.metal:29–34`) —
  matches Evan Wallace / IQ recipe (§3.5).
- Forward scroll on `wz` not `t`, bass-modulated (`:130`).
- Sun anchored to horizon via `horizonNDCy = -pitch` (`:89`) — correct.
- Sun body gradient sunWarm → sunHot (`:102`).
- Sun slits use `step(duty, fract(b*freq))` (`:112`) with widening `freq`
  and `duty` interpolated across `b ∈ [0, 0.70]` — matches §3.3.
- Exponential fog `exp(-dist*0.06)` (`:144`).
- Horizon haze mix into `skyWarm` (`:163–164`).
- Neon bloom via `smoothstep(0.15, 0, min(...))` (`:156–159`).

### Gaps vs canonical

| # | Gap | Fix location |
|---|---|---|
| G1 | Slits do **not** drift over time. The bands are static; canonical synthwave has them rolling downward like a vinyl scroll. | `Synthwave.metal:112` add `- time*0.30` inside `fract()` |
| G2 | No global `beatStrength` plumbing. `update(beat:)` receives the event but it's discarded — there is no beat flash on sun or sky. | `SynthwaveScene.update` + uniforms + fragment |
| G3 | No audio-reactive floor wobble. `bass` only modulates scroll speed; floor is rigid. | `Synthwave.metal` post-intersection bias on `gx`/`gz` |
| G4 | No mountain silhouettes. Optional but a strong signal for the genre. | new branch in `!isFloor` |
| G5 | Sun halo uses ring `smoothstep ∘ smoothstep` (`:118–120`) which is a thin annulus, not a soft falloff glow. Canonical halo is `exp(-d/0.1)` extending outward. | `Synthwave.metal:118–120` |
| G6 | Star density is fine but stars never fade near sun in **azimuth** — only in altitude. A bright star next to the sun looks wrong. | optional: damp `tw` by `1 - smoothstep(sunR*1.5, sunR*3, dSun)` |
| G7 | `bass` smoothing α = 0.10 is reasonable but `rms` is not smoothed at all. Sun rim can pop on percussive transients. | `SynthwaveScene.update` smooth `rms` symmetrically |
| G8 | No drift on slits' phase = no parallax cue inside the sun. | covered by G1 |
| G9 | Sky gradient samples palette at 0.05/0.40/0.78 — works, but for a *true* Outrun palette the top should be deep indigo, not whatever the user's palette has at 0.05. Consider hard-coding a fallback gradient that mixes with palette by, e.g., 50/50. | `Synthwave.metal:57–65` |
| G10 | `beatStrength` uniform is missing entirely from `SWUniforms`. | `Synthwave.metal:4–9` + Swift uniforms tuple |

### Verified-correct: ray-plane intersection

Lines `:124–127`:

```
float t = -1.0 / ray.y;        // valid only when ray.y < 0 (guarded by isFloor)
float wx = ray.x * t;
float wz = ray.z * t;
```

This is the textbook `(h - O.y) / D.y` with `O = 0` and `h = -1`. Sign
is correct: `ray.y < 0` ⇒ `t > 0`. `ray.z = -1` after normalize-ish
(actually `-1/|ray|`) ⇒ `wz < 0`, growing more negative as the horizon
approaches — exactly what we want for the scroll bias. **No change
needed here.**

## 7. Concrete fix list (ordered, minimal)

1. **Add `beatStrength` to `SWUniforms`** and pass it from
   `SynthwaveScene.encode`. In `update(beat:)`, set
   `beatStrength = max(beatStrength * exp(-dt*6), beat?.strength ?? 0)`
   so it decays smoothly between beats.
2. **Drift the sun slits**: change
   `step(duty, fract(b * freq + 0.5))` → `step(duty, fract(b * freq - u.time * 0.30))`.
3. **Replace the sun rim** (`:118–120`) with a soft halo:
   `float halo = exp(-max(dSun - sunR, 0.0) / 0.10);`
   `col += sunHot * halo * (0.18 + 0.40*u.rms + 0.30*u.beatStrength);`
4. **Floor wobble**: after computing `gx`, `gz`, add
   `float w = u.bass * 0.10 * sin(gz*0.5 + u.time*1.5); gx += w*0.3; gz += w;`
5. **Global beat flash**: just before `return float4(col,1)`, add
   `col += float3(0.06, 0.02, 0.10) * u.beatStrength;`
6. **Smooth rms** in Swift (`SynthwaveScene.update`):
   `smoothedRMS += (spectrum.rms - smoothedRMS) * 0.15`
   and pass that instead of raw `spectrum.rms`.
7. **(Optional) Mountains**: in the `!isFloor` branch, after stars,
   before sun, add the 1D-fbm silhouette from §3.4. Use the darkest
   palette tap. Costs ~5 ALU ops; high genre payoff.
8. **(Optional) Star damping near sun**: multiply `tw` by
   `1.0 - smoothstep(sunR*1.5, sunR*3.0, dSun)`.
9. **Hard-code a fallback Outrun gradient** mixed 50/50 with palette,
   so even on a bad palette the sky still reads as synthwave:
   `skyTopFix = mix(palette(0.05).rgb, float3(0.10, 0.02, 0.20), 0.5);`
   (and similarly for `skyMid`, `skyWarm`).
10. **Verify with `/usr/bin/log stream`** that no per-frame branch
    diverges catastrophically (the IF on `isFloor` is fine on Apple
    GPUs but Metal's warp width is 32 — if both branches are heavy,
    consider unifying with a `mix(skyCol, floorCol, step(0, ray.y))`).

## 8. References

1. Shadertoy *Synthwave Shader [VIP2017]* — `https://www.shadertoy.com/view/MslfRn`
2. Shadertoy *Retro synthwave* — `https://www.shadertoy.com/view/WljfRc`
3. Shadertoy *Synthwave grid landscape* — `https://www.shadertoy.com/view/NsScWt`
4. Shadertoy *Synthwave grid* — `https://www.shadertoy.com/view/dt2SDt`
5. Inigo Quilez, *Ray-surface intersectors* — `https://iquilezles.org/articles/intersectors/`
   (ray-plane formula `t = -(dot(ro,n)+d)/dot(rd,n)`)
6. Evan Wallace, *Anti-aliased grid shader* — `https://madebyevan.com/shaders/grid/`
   (the `fwidth` filtered-grid trick)
7. Possumwood wiki, *Infinite ground plane using GLSL shaders* —
   `https://github.com/martin-pr/possumwood/wiki/Infinite-ground-plane-using-GLSL-shaders`
8. Inigo Quilez, *fBM* — `https://iquilezles.org/articles/fbm/`
   (1D noise for mountain silhouettes)
9. Godot Shaders, *Retro Sun* — `https://godotshaders.com/shader/retro-sun/`
   (the loop-based scanline cutout idiom)
10. *The Ultimate Outrun Color Palette Guide* — `https://retrowave.com/the-ultimate-outrun-color-palette-guide-for-retro-vibes/`
    (canonical hex values for sky/sun/grid)
