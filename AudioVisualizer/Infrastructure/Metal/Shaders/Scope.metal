#include <metal_stdlib>
using namespace metal;

// Canonical phosphor-style oscilloscope. Per segment between two consecutive
// samples we draw a quad oriented along the segment, then in the fragment
// stage we compute the signed distance to the line and AA it with `fwidth`.
// A Gaussian halo around the core gives the bloom feel.

struct ScopeUniforms {
    float aspect;
    float time;
    float coreRadius;     // line core thickness in NDC.y units
    float haloSigma;      // gaussian halo width in NDC.y units
    float beatBoost;      // 0..1 — multiplies whole-line brightness
};

struct ScopeOut {
    float4 position [[position]];
    float2 worldPos;     // fragment position in NDC (passed for SDF maths)
    float2 segA;         // segment start in NDC
    float2 segB;         // segment end in NDC
    float  t;            // 0..1 horizontal position (for palette gradient)
};

// Inigo Quilez sdSegment.
static inline float sdSegment(float2 p, float2 a, float2 b) {
    float2 pa = p - a;
    float2 ba = b - a;
    float h = saturate(dot(pa, ba) / max(dot(ba, ba), 1e-8));
    return length(pa - ba * h);
}

vertex ScopeOut scope_vertex(uint vid [[vertex_id]],
                             uint iid [[instance_id]],
                             constant float *samples [[buffer(0)]],
                             constant uint &sampleCount [[buffer(1)]],
                             constant ScopeUniforms &u [[buffer(2)]]) {
    // Segment iid connects samples[iid] and samples[iid+1].
    uint i0 = iid;
    uint i1 = min(iid + 1, sampleCount - 1);

    float x0 = -1.0 + 2.0 * float(i0) / float(sampleCount - 1);
    float x1 = -1.0 + 2.0 * float(i1) / float(sampleCount - 1);
    float y0 = samples[i0];
    float y1 = samples[i1];
    float2 a = float2(x0, y0);
    float2 b = float2(x1, y1);

    // Quad expanded by half the segment's perpendicular footprint, padded so
    // the AA falloff (halo) stays inside the quad even on near-horizontal segments.
    float pad = max(u.coreRadius + u.haloSigma * 3.0, 0.012);
    float2 along = b - a;
    // Compensate for aspect when computing the perpendicular so the line thickness
    // looks consistent on widescreen canvases.
    along.x *= u.aspect;
    float lenAlong = max(length(along), 1e-6);
    float2 dir = along / lenAlong;
    float2 nor = float2(-dir.y, dir.x);
    nor.x /= u.aspect;

    float2 quad[6] = { a - nor * pad, b - nor * pad, a + nor * pad,
                       b - nor * pad, b + nor * pad, a + nor * pad };

    ScopeOut o;
    o.position = float4(quad[vid], 0.0, 1.0);
    o.worldPos = quad[vid];
    o.segA = a;
    o.segB = b;
    o.t = float(i0) / float(max(1u, sampleCount - 1));
    return o;
}

fragment float4 scope_fragment(ScopeOut in [[stage_in]],
                               constant ScopeUniforms &u [[buffer(0)]],
                               texture2d<float> palette [[texture(0)]]) {
    constexpr sampler s(filter::linear);

    // Aspect-correct distance so the line has consistent perceived width.
    float2 p = in.worldPos;
    float2 a = in.segA;
    float2 b = in.segB;
    p.x *= u.aspect; a.x *= u.aspect; b.x *= u.aspect;
    float d = sdSegment(p, a, b);

    // Crisp 1-px-ish core.
    float w = fwidth(d) + 1e-5;
    float core = 1.0 - smoothstep(u.coreRadius, u.coreRadius + w, d);
    // Soft phosphor halo — exponential falloff.
    float halo = exp(-(d * d) / max(u.haloSigma * u.haloSigma, 1e-6));

    // Palette gradient along the trace.
    float3 base = palette.sample(s, float2(0.20 + in.t * 0.65, 0.5)).rgb;
    float intensity = (core + halo * 0.55) * (1.0 + 1.50 * u.beatBoost);
    float3 col = base * intensity;
    // Whiten the very centre on loud passages.
    col = mix(col, float3(1.0), core * 0.30);

    // Additive blending owns the alpha; emit pre-multiplied so glow accumulates.
    return float4(col, intensity);
}
