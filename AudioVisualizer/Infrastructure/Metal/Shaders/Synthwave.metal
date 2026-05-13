#include <metal_stdlib>
using namespace metal;

struct SWUniforms {
    float aspect;
    float time;
    float rms;
    float bass;
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

// Filtered grid line: returns a [0, 1] mask that's 1 *on* a grid line and
// fades to 0 between them, with anti-aliasing pulled from the derivative of
// the world coordinate. Same idea as the Godot reference shader — distant
// lines fade automatically instead of moiréing.
static inline float filteredGrid(float coord, float spacing, float thickness) {
    float c = fmod(coord + 1000.0, spacing);           // wrap
    float d = min(c, spacing - c);                     // distance to nearest line
    float w = fwidth(coord);                           // per-pixel rate of change
    return smoothstep(thickness + w, thickness - w, d);
}

// Synthwave / Outrun look — sky + half-sun + perspective neon grid.
//
// Implemented as a per-pixel ray-plane intersection (the technique used in
// the well-known Shadertoy synthwave shaders): treat each fragment as a ray
// from a virtual camera at y = 1 and intersect with a plane at y = 0 to
// recover proper world coordinates on the floor. Perspective then comes for
// free from the inverse of rayDir.y, and `fwidth` on the world coordinates
// gives screen-space-correct anti-aliasing — no moiré at the horizon.
fragment float4 synth_fragment(SWOut in [[stage_in]],
                               constant SWUniforms &u [[buffer(1)]],
                               texture2d<float> palette [[texture(0)]]) {
    constexpr sampler s(filter::linear);

    // Screen → camera ray. Shift uv.y so the horizon sits slightly below
    // centre on screen; bass adds a tiny sag for life.
    float2 uv = in.ndc;
    uv.x *= u.aspect;
    float pitch = 0.18 + u.bass * 0.04;                 // horizon offset
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
        // Gradient indexed by ray.y above the horizon (0 → 1).
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
        // Anchored to the horizon on screen — we project a point at world
        // y = 0, z = -2 (in front of the camera) back to screen NDC by
        // reversing the ray formula, then draw a screen-space disc there.
        float horizonNDCy = -pitch;                     // where ray.y = 0 hits screen
        float2 sunC = float2(0.0, horizonNDCy + 0.05);
        float  sunR = 0.32;
        float  dSun = length(float2(uv.x, in.ndc.y) - sunC);

        if (dSun < sunR + 0.06) {
            float aa   = fwidth(dSun) + 0.001;
            float disc = 1.0 - smoothstep(sunR - aa, sunR + aa, dSun);

            // 0 at horizon (= bottom of visible half-disc), 1 at the top.
            float yIn = clamp((in.ndc.y - sunC.y) / sunR, 0.0, 1.0);

            // Body: warm at horizon, hot at top.
            float3 body = mix(sunWarm, sunHot, smoothstep(0.0, 1.0, yIn));

            // Slits: only the lower 70% of the visible half. Bands widen and
            // become more open as they approach the horizon (the classic
            // Miami-Vice taper).
            float slits = 1.0;
            if (yIn < 0.70) {
                float b    = yIn / 0.70;                // 0 at horizon, 1 at top of slit band
                float freq = mix(6.0, 16.0, b);
                float duty = mix(0.28, 0.55, b);
                slits = step(duty, fract(b * freq + 0.5));
            }

            col = mix(col, body, disc * slits);

            // Outer rim — RMS-modulated, never strobes.
            float rim = smoothstep(sunR + 0.06, sunR - 0.02, dSun) *
                        smoothstep(sunR - 0.02, sunR + 0.06, dSun);
            col += sunHot * rim * (0.20 + u.rms * 0.40);
        }
    } else {
        // ============ FLOOR ============
        // Ray-plane intersection with y = -1 (camera height = 1).
        float t = -1.0 / ray.y;
        float wx = ray.x * t;
        float wz = ray.z * t;

        // Forward scroll. Bass gooses the throttle.
        float scroll = u.time * (1.2 + u.bass * 2.4);
        float gx = wx;
        float gz = wz + scroll;

        // Filtered AA grid in *world* space — perspective comes for free.
        float spacing   = 1.0;
        float thickness = 0.040;
        float lineX = filteredGrid(gx, spacing, thickness);
        float lineZ = filteredGrid(gz, spacing, thickness);
        float grid  = max(lineX, lineZ);

        // Distance fade: grid melts into the horizon haze instead of
        // aliasing into garbage as |t| grows.
        float dist = abs(t);
        float fade = exp(-dist * 0.06);

        // Floor base: warmer/brighter up close, darker far away.
        float closeness = 1.0 - clamp(dist * 0.025, 0.0, 1.0);
        col = mix(floorD, floorM, closeness);

        // Composite the grid.
        col = mix(col, lineCol, grid * fade);

        // Neon bloom — adds glow around each line without changing its
        // sharpness. Wider in screen space far away (because fwidth grew),
        // narrower up close.
        float bloom = smoothstep(0.15, 0.0,
                                 min(min(fract(gx), 1.0 - fract(gx)),
                                     min(fract(gz), 1.0 - fract(gz))));
        col += lineCol * bloom * 0.18 * fade;

        // Horizon haze — warm wash right at the horizon line so the grid
        // dissolves smoothly into the sky.
        float horizonFade = smoothstep(0.0, 0.18, -ray.y);
        col = mix(skyWarm, col, horizonFade);
    }

    return float4(col, 1.0);
}
