#include <metal_stdlib>
using namespace metal;

// Synthwave / Outrun — fully palette-driven. Every colour role samples from
// the user-selected palette texture at a fixed `u` so the composition reads
// the same shape regardless of palette but takes on whatever colour theme
// the user chose. The bundled "Synthwave" palette was designed with these
// exact sample positions in mind (near-black ground at u≈0, deep navy sky
// at u≈0.12, deep purple at u≈0.35, magenta at u≈0.50, hot pink at u≈0.65,
// pink-orange at u≈0.78, orange at u≈0.90, laser-lemon at u≈0.97). Other
// palettes (Sunset, Aurora, Ocean, etc.) produce their own coloured takes
// of the same composition.

struct SWUniforms {
    float aspect;
    float time;
    float rms;
    float bass;
    float beat;
    float _pad0;
    float _pad1;
    float _pad2;
};

struct SWOut {
    float4 position [[position]];
    float2 ndc;
};

vertex SWOut synth_vertex(uint vid [[vertex_id]]) {
    float2 v[6] = { float2(-1,-1), float2(1,-1), float2(-1,1),
                    float2(1,-1),  float2(1,1),  float2(-1,1) };
    SWOut o;
    o.position = float4(v[vid], 0, 1);
    o.ndc = v[vid];
    return o;
}

static inline float filteredGrid(float coord, float spacing, float thickness) {
    float c = fmod(coord + 1000.0, spacing);
    float d = min(c, spacing - c);
    float w = fwidth(coord);
    return smoothstep(thickness + w, thickness - w, d);
}

static inline float hash11(float x) {
    return fract(sin(x * 12.9898) * 43758.5453);
}
static inline float vnoise1(float x) {
    float i = floor(x);
    float f = fract(x);
    float a = hash11(i);
    float b = hash11(i + 1.0);
    float u = f * f * (3.0 - 2.0 * f);
    return mix(a, b, u);
}

// Ridged fBm — `1 - |2v-1|` produces V-shaped peaks; v² sharpens them.
static inline float ridgedFBM(float x, int octaves) {
    float n = 0.0;
    float amp = 0.5;
    float freq = 1.0;
    for (int i = 0; i < octaves; i++) {
        float v = vnoise1(x * freq);
        v = 1.0 - fabs(v * 2.0 - 1.0);
        v = v * v;
        n += v * amp;
        amp *= 0.5;
        freq *= 2.0;
    }
    return n;
}

fragment float4 synth_fragment(SWOut in [[stage_in]],
                               constant SWUniforms &u [[buffer(1)]],
                               texture2d<float> palette [[texture(0)]]) {
    constexpr sampler s(filter::linear);

    float2 ndc = in.ndc;
    float  aspect = u.aspect;
    float  ax = ndc.x * aspect;

    float horizonY = 0.05 + u.bass * 0.03;

    // Palette taps — every colour role driven by the user's chosen palette.
    // The "hot" roles (neon, horizon, sun tip) slide upward along the palette on
    // beats so the same palette pulses warmer on hits without us hardcoding any
    // colour. Bass adds a small steady warmth bias to the halo/horizon.
    float beatU = clamp(u.beat, 0.0, 1.0);
    float bassU = clamp(u.bass, 0.0, 1.0);
    float3 colGround    = palette.sample(s, float2(0.00, 0.5)).rgb;
    float3 colSkyTop    = palette.sample(s, float2(0.12, 0.5)).rgb;
    float3 colBackEdge  = palette.sample(s, float2(0.22, 0.5)).rgb;
    float3 colSkyMid    = palette.sample(s, float2(0.35, 0.5)).rgb;
    float3 colMtFill    = palette.sample(s, float2(0.50, 0.5)).rgb;
    float3 colNeon      = palette.sample(s, float2(clamp(0.65 + beatU * 0.08, 0.0, 0.98), 0.5)).rgb;
    float3 colHorizon   = palette.sample(s, float2(clamp(0.78 + beatU * 0.05 + bassU * 0.03, 0.0, 0.98), 0.5)).rgb;
    float3 colFrontEdge = palette.sample(s, float2(0.90, 0.5)).rgb;
    float3 colSunHot    = palette.sample(s, float2(clamp(0.97 + beatU * 0.02, 0.0, 1.00), 0.5)).rgb;

    float3 col = colGround;

    // ============ SKY GRADIENT ============
    if (ndc.y > horizonY) {
        float t = (ndc.y - horizonY) / (1.0 - horizonY);
        col = colHorizon;
        col = mix(col, colMtFill, smoothstep(0.05, 0.30, t));
        col = mix(col, colSkyMid, smoothstep(0.30, 0.65, t));
        col = mix(col, colSkyTop, smoothstep(0.65, 1.00, t));

        // Sparse twinkling stars in the upper region only. Tinted by the palette's
        // hottest tap (with a tiny per-star palette wobble) so they sit inside the
        // palette family rather than reading as pure white.
        if (t > 0.35) {
            float2 g = floor(ndc * float2(180.0, 90.0));
            float n = fract(sin(dot(g, float2(127.1, 311.7))) * 43758.5453);
            if (n > 0.997) {
                float tw = 0.5 + 0.5 * sin(u.time * (n * 6.0) + n * 30.0);
                float3 starTint = palette.sample(s, float2(0.85 + n * 0.12, 0.5)).rgb;
                col += starTint * tw * (t - 0.30) * 1.20;
            }
        }
    }

    // ============ SUN ============
    // Drawn before mountains so they occlude its lower edge.
    float sunBob = sin(u.time * 0.50) * 0.010;
    float2 sunC  = float2(0.0, horizonY + 0.20 + sunBob);
    float  sunR  = 0.34 + u.bass * 0.04;
    float2 dV    = float2(ax - sunC.x, ndc.y - sunC.y);
    float  dSun  = length(dV);

    if (dSun < sunR + 0.50) {
        float aa   = fwidth(dSun) + 0.001;
        float disc = 1.0 - smoothstep(sunR - aa, sunR + aa, dSun);

        // 4-stop vertical gradient inside the disc — bottom = magenta-ish,
        // middle = hot pink, upper = warm horizon, top = brightest palette tap.
        float yNorm = clamp((ndc.y - (sunC.y - sunR)) / (2.0 * sunR), 0.0, 1.0);
        float3 sunBody = colMtFill;
        sunBody = mix(sunBody, colNeon,    smoothstep(0.30, 0.55, yNorm));
        sunBody = mix(sunBody, colHorizon, smoothstep(0.55, 0.82, yNorm));
        sunBody = mix(sunBody, colSunHot,  smoothstep(0.82, 0.96, yNorm));

        // Horizontal slits — denser toward bottom, drifting downward.
        float yBottom = 1.0 - yNorm;
        float slits = 1.0;
        if (yBottom > 0.18) {
            float b    = (yBottom - 0.18) / 0.82;
            float freq = mix(10.0, 32.0, b);
            float duty = mix(0.58, 0.32, b);
            slits = step(duty, fract(yBottom * freq - u.time * 0.25));
        }
        col = mix(col, sunBody, disc * slits);

        // Halo — RMS / beat modulated.
        float haloT = max(0.0, 1.0 - (dSun - sunR) / 0.40);
        col += colNeon * pow(haloT, 3.0) * (0.45 + 0.30 * u.rms + 0.55 * u.beat);
    }

    // ============ MOUNTAINS (2D silhouettes) ============
    if (ndc.y > horizonY) {
        float scrollMt = u.time * 0.04;
        float dyAbove  = ndc.y - horizonY;

        // Back range — broader peaks, lower amplitude, cool rim tap.
        float backX = (ax + scrollMt) * 2.2 + 1.0;
        float backH = ridgedFBM(backX, 4) * 0.18 * (0.55 + u.bass * 0.65) + 0.030;
        if (dyAbove < backH) {
            col = mix(col, colSkyMid * 0.55 + colMtFill * 0.20, 0.85);
            float edge = backH - dyAbove;
            float hl   = smoothstep(0.014, 0.0, edge);
            col += colBackEdge * hl * 1.40;
        }

        // Front range — taller, sharper, warm rim tap.
        float frontX = (ax + scrollMt * 1.8 + 8.3) * 3.4;
        float frontH = ridgedFBM(frontX, 5) * 0.28 * (0.60 + u.bass * 0.85) + 0.020;
        if (dyAbove < frontH) {
            col = mix(col, colMtFill * 0.22 + colGround * 0.50, 0.95);
            float edge = frontH - dyAbove;
            float hl   = smoothstep(0.016, 0.0, edge);
            col += colFrontEdge * hl * 1.30;
        }
    }

    // ============ HORIZON GLOW BAND ============
    col += colHorizon * exp(-pow((ndc.y - horizonY) * 45.0, 2.0)) * 0.35;

    // ============ GRID FLOOR (canonical retrowave perspective) ============
    if (ndc.y < horizonY) {
        float dyBelow = horizonY - ndc.y;

        float2 uv;
        uv.y = 3.0 / (dyBelow + 0.06);
        uv.x = ax * uv.y * 0.10;
        uv.y -= u.time * (1.5 + u.bass * 2.5);

        float2 cell = abs(fract(uv) - 0.5);
        float2 fw   = max(fwidth(uv), float2(0.0002));
        float  lw   = 0.040;
        float  lineX = smoothstep(lw + fw.x, lw - fw.x, cell.x);
        float  lineY = smoothstep(lw + fw.y, lw - fw.y, cell.y);
        float  halo  = smoothstep(lw * 4.0, 0.0, min(cell.x, cell.y)) * 0.45;
        float  grid  = max(lineX, lineY) + halo;

        float lightWave = 0.55 + 0.45 * sin(uv.y * 0.4 + u.time * 0.6);
        float gridPulse = 1.0 + 0.45 * u.beat + 0.30 * lightWave;

        col = mix(colGround, colSkyTop * 0.35, 1.0 - exp(-dyBelow * 1.5));
        col += colNeon * grid * gridPulse;

        // Sun reflection — vertical warm streak directly under the sun.
        float dxScreen = fabs(ax);
        col += colHorizon
             * exp(-dxScreen * dxScreen * 80.0)
             * exp(-dyBelow * 2.5)
             * (0.55 + 0.30 * u.rms);
    }

    // ============ GLOBAL BEAT FLASH ============
    col += colNeon * u.beat * 0.06;

    return float4(col, 1.0);
}
