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

// Synthwave / vaporwave scene — sun on the horizon and a retreating neon grid.
// All procedural; no mesh, no vertex deformation needed. The grid is computed
// in screen-space using a perspective remap of v ∈ [0, 1] (foreground →
// horizon) which gives the classic Tron-style infinite-floor look.
fragment float4 synth_fragment(SWOut in [[stage_in]],
                               constant SWUniforms &u [[buffer(1)]],
                               texture2d<float> palette [[texture(0)]]) {
    constexpr sampler s(filter::linear);
    float2 p = in.ndc;
    p.x *= u.aspect;

    // Horizon at y = 0. Below is the grid floor, above is the sky + sun.
    float horizonY = 0.05 + u.bass * 0.08;

    // ---- Sky / sun ----------------------------------------------------------
    float3 skyTop = palette.sample(s, float2(0.05, 0.5)).rgb;
    float3 skyMid = palette.sample(s, float2(0.55, 0.5)).rgb;
    float3 skyBot = palette.sample(s, float2(0.85, 0.5)).rgb;
    float skyT = clamp((in.ndc.y - horizonY) / (1.0 - horizonY + 0.0001), 0.0, 1.0);
    float3 sky = mix(skyBot, mix(skyMid, skyTop, skyT), skyT);
    // The sun: a circle sitting on the horizon, with horizontal stripe cutouts.
    float2 sunC = float2(0.0, horizonY + 0.18);
    float sunR = 0.32;
    float dSun = length((p - sunC) / float2(1.0, 1.05));
    float sunBody = 1.0 - smoothstep(sunR - 0.02, sunR, dSun);
    // Stripes carved into the lower half of the sun for the "rising" look.
    float yRel = (sunC.y - p.y) / sunR;                   // 0 at top of sun, 1 at bottom
    float stripeMask = step(0.10, yRel) *
                       step(0.5, fract(yRel * 4.0 + 0.5)); // black bands
    sunBody *= (1.0 - stripeMask);
    float3 sunCol = mix(float3(1.0, 0.55, 0.25),
                        float3(1.0, 0.95, 0.45),
                        smoothstep(0.0, 1.0, yRel * -1.0 + 1.0));
    float3 col = mix(sky, sunCol, sunBody);

    // ---- Grid floor ---------------------------------------------------------
    if (in.ndc.y < horizonY) {
        // Map ndc.y in [-1, horizonY] to v ∈ [0, 1] for floor coordinate.
        float ftop = horizonY - 0.001;
        float v = clamp((ftop - in.ndc.y) / (ftop - (-1.0)), 0.0, 0.999);
        // Perspective: rows compress toward the horizon (v→0).
        float z = 1.0 / max(0.02, (1.0 - v));
        float gridZ = fract(z * 0.6 + u.time * (0.35 + u.bass * 0.55));
        float lineV = 1.0 - smoothstep(0.0, 0.04, fabs(gridZ - 0.0)) *
                       smoothstep(0.0, 0.04, fabs(gridZ - 1.0));
        // Horizontal lines (rows in perspective)
        float row = exp(-min(gridZ, 1.0 - gridZ) * 80.0);

        // Vertical lines (columns); width grows with distance to horizon to
        // simulate perspective fanning out at the bottom.
        float u_pers = p.x * z;
        float colCoord = fract(u_pers * 1.4);
        float colLine = exp(-min(colCoord, 1.0 - colCoord) * (90.0 - 60.0 * v));

        float gridIntensity = (row + colLine) * (1.0 - v * 0.75);
        float3 gridCol = palette.sample(s, float2(0.30 + 0.5 * (1.0 - v), 0.5)).rgb;
        col = mix(col, gridCol, clamp(gridIntensity, 0.0, 1.0));

        // Floor base gradient (under-grid wash).
        float3 floorBase = palette.sample(s, float2(0.85, 0.5)).rgb;
        col = mix(col, floorBase, (1.0 - v) * 0.18);
    }

    // RMS pump on the sun rim — gentle, no strobe.
    float rim = smoothstep(sunR, sunR - 0.05, dSun) * u.rms * 0.4;
    col += float3(1.0, 0.6, 0.3) * rim;

    return float4(col, 1.0);
}
