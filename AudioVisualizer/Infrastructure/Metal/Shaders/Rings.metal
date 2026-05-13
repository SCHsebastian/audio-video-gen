#include <metal_stdlib>
using namespace metal;

struct RingsUniforms {
    float aspect;
    float time;
    int   ringCount;       // active ring count
    float rms;
};

// One active ring instance — center radius, current alpha, palette U.
struct Ring {
    float radius;
    float alpha;
    float width;
    float paletteU;
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

// Iterate the (small) active-ring buffer per fragment, accumulate each ring's
// Gaussian contribution sampled from the palette. Cheaper than instancing
// because ringCount stays modest (~32) and overlap reads cleanly via additive
// blend at the call site.
fragment float4 rings_fragment(RVertOut in            [[stage_in]],
                               constant Ring *rings    [[buffer(0)]],
                               constant RingsUniforms &u [[buffer(1)]],
                               texture2d<float> palette [[texture(0)]]) {
    constexpr sampler s(filter::linear);

    float2 p = in.ndc;
    p.x *= u.aspect;
    float dist = length(p);

    // Subtle inner halo so the center never goes pitch black.
    float halo = exp(-dist * 4.5) * (0.05 + u.rms * 0.10);

    float3 col   = float3(0.0);
    float  alpha = halo;

    for (int i = 0; i < u.ringCount; i++) {
        Ring r = rings[i];
        float d = dist - r.radius;
        // Gaussian ring profile; thinner rings on younger spawn, thicker as
        // they age (CPU sets r.width). 0.012 is the floor.
        float w = max(r.width, 0.012);
        float intensity = exp(-(d * d) / (w * w)) * r.alpha;
        float3 base = palette.sample(s, float2(r.paletteU, 0.5)).rgb;
        col   += base * intensity;
        alpha += intensity;
    }
    // Soft ceiling so very dense ring stacks don't bloom out.
    alpha = min(alpha, 1.0);
    col  += float3(halo) * 0.6;
    return float4(col, alpha);
}
