#include <metal_stdlib>
using namespace metal;

// Phosphor-persistence Lissajous / parametric trace.
//
// Per frame:
//   1) Decay pass     — sample previous accumulator, multiply by exp(-dt/τ),
//                       write into current accumulator. Models CRT phosphor.
//   2) Trace pass     — render N segments of the parametric curve into the
//                       same accumulator with additive SDF anti-aliasing.
//   3) Composite pass — sample accumulator, tonemap, write to the drawable.

// -- uniforms --------------------------------------------------------------

struct LiDecayUniforms {
    float decay;
};

struct LiTraceUniforms {
    float aspect;
    float coreRadius;     // NDC.y half-width of the bright core
    float haloSigma;      // NDC.y width of the gaussian halo
    float intensity;
};

struct LiCompUniforms {
    float aspect;
    float gamma;
    float gain;
    float beat;
};

// -- decay pass ------------------------------------------------------------

struct LiVOut {
    float4 position [[position]];
    float2 uv;
};

vertex LiVOut li_full_vertex(uint vid [[vertex_id]]) {
    float2 v[6] = { float2(-1,-1), float2(1,-1), float2(-1,1),
                    float2(1,-1),  float2(1,1),  float2(-1,1) };
    LiVOut o;
    o.position = float4(v[vid], 0, 1);
    o.uv = v[vid] * 0.5 + 0.5;
    return o;
}

fragment float4 li_decay_fragment(LiVOut in [[stage_in]],
                                  constant LiDecayUniforms &u [[buffer(0)]],
                                  texture2d<float> prev [[texture(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float3 c = prev.sample(s, in.uv).rgb;
    return float4(c * u.decay, 1.0);
}

// -- trace pass (instanced quads, SDF segment AA) --------------------------

struct LiTraceOut {
    float4 position [[position]];
    float2 worldPos;
    float2 segA;
    float2 segB;
    float  t;
};

static inline float sdSegmentLi(float2 p, float2 a, float2 b) {
    float2 pa = p - a, ba = b - a;
    float h = saturate(dot(pa, ba) / max(dot(ba, ba), 1e-8));
    return length(pa - ba * h);
}

vertex LiTraceOut li_trace_vertex(uint vid [[vertex_id]],
                                  uint iid [[instance_id]],
                                  constant float2 *points [[buffer(0)]],
                                  constant uint &count [[buffer(1)]],
                                  constant LiTraceUniforms &u [[buffer(2)]]) {
    uint i0 = iid;
    uint i1 = min(iid + 1, count - 1);
    float2 a = points[i0];
    float2 b = points[i1];

    // Expand segment to a quad in aspect-corrected space.
    float2 along = b - a;
    along.x *= u.aspect;
    float len = max(length(along), 1e-6);
    float2 dir = along / len;
    float2 nor = float2(-dir.y, dir.x);
    nor.x /= u.aspect;

    float pad = max(u.coreRadius + u.haloSigma * 3.0, 0.010);

    float2 quad[6] = { a - nor*pad, b - nor*pad, a + nor*pad,
                       b - nor*pad, b + nor*pad, a + nor*pad };

    LiTraceOut o;
    o.position = float4(quad[vid], 0.0, 1.0);
    o.worldPos = quad[vid];
    o.segA = a;
    o.segB = b;
    o.t = float(i0) / float(max(1u, count - 1));
    return o;
}

fragment float4 li_trace_fragment(LiTraceOut in [[stage_in]],
                                  constant LiTraceUniforms &u [[buffer(0)]],
                                  texture2d<float> palette [[texture(0)]]) {
    constexpr sampler s(filter::linear);

    // Aspect-correct distance.
    float2 p = in.worldPos; p.x *= u.aspect;
    float2 a = in.segA;     a.x *= u.aspect;
    float2 b = in.segB;     b.x *= u.aspect;
    float d = sdSegmentLi(p, a, b);

    float w = fwidth(d) + 1e-5;
    float core = 1.0 - smoothstep(u.coreRadius, u.coreRadius + w, d);
    float halo = exp(-(d * d) / max(u.haloSigma * u.haloSigma, 1e-6));
    float intensity = (core + halo * 0.40) * u.intensity;

    float3 base = palette.sample(s, float2(0.40 + in.t * 0.55, 0.5)).rgb;
    float3 col = base * intensity;
    col = mix(col, float3(1.0), core * 0.25);
    return float4(col, intensity);
}

// -- composite pass --------------------------------------------------------

fragment float4 li_composite_fragment(LiVOut in [[stage_in]],
                                      constant LiCompUniforms &u [[buffer(0)]],
                                      texture2d<float> accum [[texture(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float3 c = accum.sample(s, in.uv).rgb;
    // Soft tonemap so phosphor build-up doesn't clip to white.
    c = c / (1.0 + c);
    c = pow(c, float3(u.gamma));
    c *= u.gain * (1.0 + 0.30 * u.beat);
    return float4(c, 1.0);
}
