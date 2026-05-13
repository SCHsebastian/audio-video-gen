#include <metal_stdlib>
using namespace metal;

struct ScopeUniforms { float thickness; float aspect; float time; float _pad; };

struct ScopeOut {
    float4 position [[position]];
    float  ny;       // -1 .. +1 across the strip thickness
    float  t;        //  0 .. 1 along the strip
};

vertex ScopeOut scope_vertex(uint vid [[vertex_id]],
                             constant float *samples [[buffer(0)]],
                             constant uint &sampleCount [[buffer(1)]],
                             constant ScopeUniforms &u [[buffer(2)]]) {
    uint sIdx = vid / 2;
    if (sIdx >= sampleCount) sIdx = sampleCount - 1;
    float x = -1.0 + 2.0 * float(sIdx) / float(sampleCount - 1);
    float y = samples[sIdx];
    float sign = (vid % 2 == 0) ? -1.0 : 1.0;
    float off = sign * u.thickness;

    ScopeOut o;
    o.position = float4(x, y + off, 0.0, 1.0);
    o.ny = sign;
    o.t = float(sIdx) / float(max(1u, sampleCount - 1));
    return o;
}

fragment float4 scope_fragment(ScopeOut in [[stage_in]],
                               constant float &alpha [[buffer(0)]],
                               texture2d<float> palette [[texture(0)]]) {
    constexpr sampler s(filter::linear);
    // Gaussian falloff across the strip — crisp centre, soft edges.
    float falloff = exp(-in.ny * in.ny * 4.5);
    float3 col = palette.sample(s, float2(0.4 + in.t * 0.5, 0.5)).rgb;
    return float4(col * falloff, alpha * falloff);
}
