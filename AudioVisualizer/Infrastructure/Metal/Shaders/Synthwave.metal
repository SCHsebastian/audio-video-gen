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

// Synthwave / Miami sun + retreating neon grid floor.
//
// Layout:
//   sky:    p.y > horizonY   — vertical gradient + half-sun w/ horizontal slits
//   floor:  p.y < horizonY   — perspective grid that vanishes at the horizon
//
// The previous version had three bugs the user spotted: depth was inverted
// (lines packed near the bottom instead of the horizon), the sun was drawn
// in *both* branches (so half of it bled under the grid), and the column
// lines aliased into a jittery mess at large depth because there was no
// derivative-aware AA. This pass fixes all three and keeps the palette-LUT
// convention so user palettes still tint the scene.
fragment float4 synth_fragment(SWOut in [[stage_in]],
                               constant SWUniforms &u [[buffer(1)]],
                               texture2d<float> palette [[texture(0)]]) {
    constexpr sampler s(filter::linear);
    float2 p = in.ndc;
    p.x *= u.aspect;

    // Horizon sits slightly below center. Tiny bass-driven sag for life.
    float horizonY = -0.08 - u.bass * 0.06;

    // Palette samples — picked so any user palette still feels synthwave.
    float3 skyTop    = palette.sample(s, float2(0.05, 0.5)).rgb;   // deep
    float3 skyMid    = palette.sample(s, float2(0.40, 0.5)).rgb;   // mid hue
    float3 skyWarm   = palette.sample(s, float2(0.78, 0.5)).rgb;   // horizon warm
    float3 sunTopCol = palette.sample(s, float2(0.95, 0.5)).rgb;
    float3 sunBotCol = palette.sample(s, float2(0.72, 0.5)).rgb;
    float3 lineCol   = palette.sample(s, float2(0.58, 0.5)).rgb;   // neon
    float3 floorDark = palette.sample(s, float2(0.10, 0.5)).rgb;
    float3 floorMid  = palette.sample(s, float2(0.20, 0.5)).rgb;

    float3 col;

    if (p.y > horizonY) {
        // ============ SKY ============
        float t = clamp((p.y - horizonY) / (1.0 - horizonY + 1e-4), 0.0, 1.0);
        // Warm at horizon, mid in the middle, deep at the top.
        col = mix(skyWarm, mix(skyMid, skyTop, t), t);

        // Twinkly stars in the upper half.
        if (t > 0.25) {
            float2 sp = float2(p.x * 9.0, p.y * 9.0);
            float starN = fract(sin(dot(floor(sp), float2(127.1, 311.7))) * 43758.5453);
            if (starN > 0.985) {
                float tw = 0.5 + 0.5 * sin(u.time * (starN * 6.0) + starN * 30.0);
                col += float3(1.0) * tw * (t - 0.25) * 0.6;
            }
        }

        // ============ SUN ============
        // Centered on the horizon — only the upper half is visible (the rest
        // would be below the floor, which we never draw in this branch).
        float2 sunC = float2(0.0, horizonY);
        float sunR  = 0.34;
        float dSun  = length(p - sunC);

        if (dSun < sunR + 0.04) {
            // Anti-aliased fill of the sun disc.
            float aa = fwidth(dSun) + 0.001;
            float disc = 1.0 - smoothstep(sunR - aa, sunR + aa, dSun);

            // Vertical position within the sun: 0 at horizon (= bottom of
            // visible half), 1 at the top of the sun.
            float yInSun = clamp((p.y - sunC.y) / sunR, 0.0, 1.0);

            // Sun body: warm bottom → hot top.
            float3 sunBody = mix(sunBotCol, sunTopCol, yInSun);

            // Horizontal slits — only on the lower 60% of the visible half,
            // 5 bands, getting wider as they approach the horizon.
            float slits = 1.0;
            if (yInSun < 0.60) {
                float band = yInSun / 0.60;                           // 0 horizon, 1 top of slits
                float freq = mix(7.0, 14.0, band);                    // wider slits near horizon
                float duty = mix(0.30, 0.55, band);                   // bigger gaps near horizon
                slits = step(duty, fract(band * freq + 0.5));
            }

            col = mix(col, sunBody, disc * slits);

            // Outer rim glow — adds RMS-driven warmth, never strobes.
            float rim = smoothstep(sunR, sunR - 0.06, dSun) *
                        smoothstep(sunR + 0.04, sunR, dSun);
            col += sunTopCol * rim * (0.20 + u.rms * 0.35);
        }
    } else {
        // ============ FLOOR ============
        // depth → ∞ at horizon, ~1 at screen bottom. Inverse-screen-y mapping.
        float depth = 1.0 / max(1e-4, horizonY - p.y);

        // Scroll forward in time; bass pushes the throttle.
        float scroll = u.time * (0.7 + u.bass * 1.8);

        // ---- horizontal lines (rows) ----
        // Lines at integer z; the fractional distance to the nearest one is
        // anti-aliased via fwidth so the line stays one pixel thick at all
        // depths instead of aliasing at the horizon.
        float zPos    = depth + scroll;
        float rowFrac = fract(zPos);
        float rowDist = min(rowFrac, 1.0 - rowFrac);
        float rowAA   = fwidth(rowDist) + 0.001;
        float rowLine = 1.0 - smoothstep(rowAA, rowAA * 3.0, rowDist);

        // ---- vertical lines (columns) ----
        // worldX = screen_x * depth gives lines that converge to a single
        // vanishing point at the horizon — the classic Tron-floor look.
        float worldX  = p.x * depth * 0.55;
        float colFrac = fract(worldX);
        float colDist = min(colFrac, 1.0 - colFrac);
        float colAA   = fwidth(colDist) + 0.001;
        float colLine = 1.0 - smoothstep(colAA, colAA * 3.0, colDist);

        // Distance fade so the grid dissolves into the horizon haze rather
        // than aliasing into noise.
        float fade = exp(-depth * 0.045);
        float grid = max(rowLine, colLine) * fade;

        // Floor base: darker far away, slightly warmer up close.
        float closeness = clamp(1.0 / depth, 0.0, 1.0);
        col = mix(floorDark, floorMid, closeness);

        // Composite grid.
        col = mix(col, lineCol, grid);

        // Neon bloom around the lines.
        float bloom = max(
            exp(-rowDist * 22.0) * fade,
            exp(-colDist * 22.0) * fade
        ) * 0.30;
        col += lineCol * bloom;

        // Horizon haze — a warm band right at the horizon line.
        float haze = exp(-(horizonY - p.y) * 18.0);
        col = mix(col, skyWarm, haze * 0.55);
    }

    return float4(col, 1.0);
}
