#include <metal_stdlib>
using namespace metal;

struct ScopeUniforms { float thickness; float aspect; float time; float _pad; };

vertex float4 scope_vertex(uint vid [[vertex_id]],
                           constant float *samples [[buffer(0)]],
                           constant uint &sampleCount [[buffer(1)]],
                           constant ScopeUniforms &u [[buffer(2)]]) {
    // Triangle strip: 2 verts per sample.
    uint sIdx = vid / 2;
    if (sIdx >= sampleCount) sIdx = sampleCount - 1;
    float x = -1.0 + 2.0 * float(sIdx) / float(sampleCount - 1);
    float y = samples[sIdx];
    float off = (vid % 2 == 0) ? -u.thickness : u.thickness;
    return float4(x, y + off, 0.0, 1.0);
}

fragment float4 scope_fragment(constant float &alpha [[buffer(0)]],
                               texture2d<float> palette [[texture(0)]]) {
    constexpr sampler s(filter::linear);
    return float4(palette.sample(s, float2(0.7, 0.5)).rgb, alpha);
}
