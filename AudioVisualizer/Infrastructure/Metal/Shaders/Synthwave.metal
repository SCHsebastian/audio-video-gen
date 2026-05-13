#include <metal_stdlib>
using namespace metal;

// Synthwave / Outrun horizon. Per-pixel ray-plane intersection for the floor
// (perfect perspective via `t = -1/ray.y`), screen-space disc + horizontal
// scanlines for the sun, audio-coupled grid scroll + bass wobble for the
// floor, plus an exponential sun-halo and global beat flash.

struct SWUniforms {
    float aspect;
    float time;
    float rms;
    float bass;
    float beat;          // 0..1 beat envelope (decays in scene)
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

// Anti-aliased "filtered grid" — distant lines smoothly fade out instead of
// moiréing. `fwidth` measures pixel footprint in world space, so far-away
// lines (where `coord` changes fast per pixel) become thicker and dimmer.
static inline float filteredGrid(float coord, float spacing, float thickness) {
    float c = fmod(coord + 1000.0, spacing);
    float d = min(c, spacing - c);
    float w = fwidth(coord);
    return smoothstep(thickness + w, thickness - w, d);
}

fragment float4 synth_fragment(SWOut in [[stage_in]],
                               constant SWUniforms &u [[buffer(1)]],
                               texture2d<float> palette [[texture(0)]]) {
    constexpr sampler s(filter::linear);

    float2 uv = in.ndc;
    uv.x *= u.aspect;
    float pitch = 0.18 + u.bass * 0.04;
    float3 ray = normalize(float3(uv.x, uv.y + pitch, -1.0));

    // Palette samples — chosen so any user palette still reads as synthwave.
    float3 skyTop  = palette.sample(s, float2(0.05, 0.5)).rgb;
    float3 skyMid  = palette.sample(s, float2(0.40, 0.5)).rgb;
    float3 skyWarm = palette.sample(s, float2(0.78, 0.5)).rgb;
    float3 sunHot  = palette.sample(s, float2(0.95, 0.5)).rgb;
    float3 sunWarm = palette.sample(s, float2(0.72, 0.5)).rgb;
    float3 lineCol = palette.sample(s, float2(0.58, 0.5)).rgb;
    float3 floorD  = palette.sample(s, float2(0.10, 0.5)).rgb;
    float3 floorM  = palette.sample(s, float2(0.22, 0.5)).rgb;

    float3 col;
    bool isFloor = (ray.y < 0.0);

    if (!isFloor) {
        // ============ SKY ============
        float t = clamp(ray.y * 1.4, 0.0, 1.0);
        col = mix(skyWarm, mix(skyMid, skyTop, t), t);

        // Twinkling stars in the upper half only.
        if (t > 0.30) {
            float2 g  = floor(uv * 9.0);
            float  n  = fract(sin(dot(g, float2(127.1, 311.7))) * 43758.5453);
            if (n > 0.985) {
                float tw = 0.5 + 0.5 * sin(u.time * (n * 6.0) + n * 30.0);
                col += float3(1.0) * tw * (t - 0.30) * 0.55;
            }
        }

        // ============ SUN ============
        float horizonNDCy = -pitch;
        float2 sunC = float2(0.0, horizonNDCy + 0.05);
        float  sunR = 0.32;
        float  dSun = length(float2(uv.x, in.ndc.y) - sunC);

        // AA disc + horizontal scanline cutouts that drift downward.
        if (dSun < sunR + 0.20) {
            float aa   = fwidth(dSun) + 0.001;
            float disc = 1.0 - smoothstep(sunR - aa, sunR + aa, dSun);

            float yIn = clamp((in.ndc.y - sunC.y) / sunR, 0.0, 1.0);
            float3 body = mix(sunWarm, sunHot, smoothstep(0.0, 1.0, yIn));

            // Slit cutouts. `- time*0.30` rolls the bands downward like vinyl.
            float slits = 1.0;
            if (yIn < 0.70) {
                float b    = yIn / 0.70;
                float freq = mix(6.0, 16.0, b);
                float duty = mix(0.28, 0.55, b);
                slits = step(duty, fract(b * freq - u.time * 0.30));
            }
            col = mix(col, body, disc * slits);

            // Soft exponential halo (replaces the old thin annular rim).
            float halo = exp(-max(dSun - sunR, 0.0) / 0.12);
            col += sunHot * halo * (0.18 + 0.40 * u.rms + 0.40 * u.beat);
        }
    } else {
        // ============ FLOOR ============
        float t = -1.0 / ray.y;
        float wx = ray.x * t;
        float wz = ray.z * t;

        float scroll = u.time * (1.2 + u.bass * 2.4);
        float gx = wx;
        float gz = wz + scroll;

        // Audio-reactive floor wobble — biases grid coords by a sinusoid
        // evaluated in world space. Visually a rippling floor, cheap to compute.
        float wobble = u.bass * 0.10 * sin(gz * 0.5 + u.time * 1.5);
        gx += wobble * 0.3;
        gz += wobble;

        float spacing   = 1.0;
        float thickness = 0.040;
        float lineX = filteredGrid(gx, spacing, thickness);
        float lineZ = filteredGrid(gz, spacing, thickness);
        float grid  = max(lineX, lineZ);

        float dist = fabs(t);
        float fade = exp(-dist * 0.06);

        float closeness = 1.0 - clamp(dist * 0.025, 0.0, 1.0);
        col = mix(floorD, floorM, closeness);
        col = mix(col, lineCol, grid * fade);

        // Neon bloom — adds glow around each line without changing its sharpness.
        float bloom = smoothstep(0.15, 0.0,
                                 min(min(fract(gx), 1.0 - fract(gx)),
                                     min(fract(gz), 1.0 - fract(gz))));
        col += lineCol * bloom * 0.18 * fade;

        // Horizon haze: grid dissolves smoothly into the warm sky band.
        float horizonFade = smoothstep(0.0, 0.18, -ray.y);
        col = mix(skyWarm, col, horizonFade);
    }

    // Global beat flash (magenta-tinted so it reads as "the sun pulsed").
    col += float3(0.06, 0.02, 0.10) * u.beat;
    return float4(col, 1.0);
}
