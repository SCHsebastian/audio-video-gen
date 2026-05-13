#include <metal_stdlib>
using namespace metal;

struct BarsUniforms {
    float aspect;
    float time;
    int barCount;
};

struct VertexOut {
    float4 position [[position]];
    float height;
};

vertex VertexOut bars_vertex(uint vid [[vertex_id]],
                             uint iid [[instance_id]],
                             constant float *heights [[buffer(0)]],
                             constant BarsUniforms &u [[buffer(1)]]) {
    float w = 2.0 / float(u.barCount);
    float x0 = -1.0 + w * float(iid) + w * 0.05;
    float x1 = x0 + w * 0.9;
    float h = heights[iid];
    float y0 = -1.0;
    float y1 = -1.0 + 2.0 * h;
    float2 verts[6] = { float2(x0,y0), float2(x1,y0), float2(x0,y1),
                        float2(x1,y0), float2(x1,y1), float2(x0,y1) };
    VertexOut out;
    out.position = float4(verts[vid], 0.0, 1.0);
    out.height = h;
    return out;
}

fragment float4 bars_fragment(VertexOut in [[stage_in]],
                              texture2d<float> palette [[texture(0)]]) {
    constexpr sampler s(filter::linear);
    return palette.sample(s, float2(in.height, 0.5));
}
