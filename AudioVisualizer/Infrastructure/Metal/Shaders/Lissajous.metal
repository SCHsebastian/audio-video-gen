#include <metal_stdlib>
using namespace metal;

struct LissajousUniforms {
    float thickness;
    float aspect;
    float time;
    float intensity;
};

struct LVertexOut {
    float4 position [[position]];
    float t;
};

// Draws a thick line strip from a 2D point buffer produced by the C++ kernel.
// Each segment is a quad (2 triangles, 6 vertices). vid = 0..5, iid = segment index.
vertex LVertexOut lissajous_vertex(uint vid [[vertex_id]],
                                   uint iid [[instance_id]],
                                   constant float2 *points [[buffer(0)]],
                                   constant uint &count [[buffer(1)]],
                                   constant LissajousUniforms &u [[buffer(2)]]) {
    uint i0 = iid;
    uint i1 = min(iid + 1, count - 1);
    float2 a = points[i0];
    float2 b = points[i1];
    // Tangent direction in screen pixels (so the perpendicular is in pixel space).
    float2 along = b - a;
    along.x *= u.aspect;
    float2 dir = normalize(along + float2(1e-6, 0));
    float2 nor = float2(-dir.y, dir.x);
    // Convert pixel-space normal back to NDC so on-screen thickness is uniform.
    nor.x /= max(0.0001, u.aspect);
    float th = u.thickness;
    float2 quad[6] = { a - nor*th, b - nor*th, a + nor*th,
                       b - nor*th, b + nor*th, a + nor*th };
    LVertexOut o;
    // Curve fills the full NDC rectangle (no /aspect on position).
    o.position = float4(quad[vid].x, quad[vid].y, 0.0, 1.0);
    o.t = float(iid) / float(max(1u, count - 1));
    return o;
}

fragment float4 lissajous_fragment(LVertexOut in [[stage_in]],
                                   constant LissajousUniforms &u [[buffer(0)]],
                                   texture2d<float> palette [[texture(0)]]) {
    constexpr sampler s(filter::linear);
    float4 col = palette.sample(s, float2(in.t, 0.5));
    col.rgb *= u.intensity;
    col.a = 1.0;
    return col;
}
