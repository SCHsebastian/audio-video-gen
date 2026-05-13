#include <metal_stdlib>
using namespace metal;

// Sonar-ping rings. Each ring is a particle with (radius, intensity, width,
// paletteU, phase). The fragment iterates the pool, accumulates a sharp-edge
// SDF "wavefront" plus a `1/d` glow. Bass and treble warp the circle along
// θ so each ring breathes in shape without losing its identity.

struct RingsUniforms {
    float aspect;
    float time;
    int   ringCount;
    float rms;
    float bass;
    float treble;
    float _pad0;
    float _pad1;
};

// 4 floats per ring slot:
//   x = radius (negative = empty slot)
//   y = intensity  ∈ [0, 1]
//   z = current line half-width (NDC)
//   w = phase  ∈ [0, 2π)  (for the angular warp + palette sample)
struct Ring {
    float radius;
    float intensity;
    float width;
    float phase;
};

struct RVertOut {
    float4 position [[position]];
    float2 ndc;
};

vertex RVertOut rings_vertex(uint vid [[vertex_id]]) {
    float2 verts[6] = { float2(-1,-1), float2(1,-1), float2(-1,1),
                        float2(1,-1),  float2(1,1),  float2(-1,1) };
    RVertOut o;
    o.position = float4(verts[vid], 0, 1);
    o.ndc = verts[vid];
    return o;
}

fragment float4 rings_fragment(RVertOut in [[stage_in]],
                               constant Ring *rings [[buffer(0)]],
                               constant RingsUniforms &u [[buffer(1)]],
                               texture2d<float> palette [[texture(0)]]) {
    constexpr sampler s(filter::linear);

    float2 p = in.ndc;
    p.x *= u.aspect;
    float r0 = length(p);
    float theta = atan2(p.y, p.x);

    // Subtle inner halo so the center is never pitch black.
    float halo = exp(-r0 * 4.5) * (0.04 + u.rms * 0.10);

    float3 col = float3(0.0);
    float alpha = halo;

    for (int i = 0; i < u.ringCount; i++) {
        Ring R = rings[i];
        if (R.radius < 0.0 || R.intensity < 1e-4) continue;

        // Spectrum warp — two harmonics, bass for big lobes, treble for shimmer.
        float rWarp = R.radius
                    + u.bass   * 0.020 * sin(8.0  * theta + R.phase)
                    + u.treble * 0.005 * sin(64.0 * theta + R.phase);

        float d = fabs(r0 - rWarp);

        // Sharp leading edge — `smoothstep` band of width `R.width`.
        float aa = fwidth(d) + 1e-5;
        float edge = 1.0 - smoothstep(R.width - aa, R.width + aa, d);
        // Wide `1/d` glow — gives the wave-packet shimmer.
        float glow = clamp(0.010 / max(d, 1e-3), 0.0, 1.0) * 0.55;

        float3 base = palette.sample(s, float2(R.phase * 0.15915494, 0.5)).rgb;  // phase/2π
        float intensity = (edge + glow) * R.intensity;
        col   += base * intensity;
        alpha += intensity;
    }

    // Soft alpha ceiling so dense overlap doesn't saturate.
    alpha = min(alpha, 1.0);
    col   += float3(halo) * 0.6;
    return float4(col, alpha);
}
