#include <metal_stdlib>
using namespace metal;

// Canonical Milkdrop / Butterchurn feedback visualizer.
//
// Three GPU passes per frame:
//   1) Warp pass     — sample previous frame texture at a per-pixel warped UV
//                      (zoom + rotate + center drift + sinusoidal warp), then
//                      multiply by a decay constant; write into curr.
//   2) Waveform pass — draw the iconic line-strip (waveform displaces a base
//                      circle in screen space) into curr with additive blending.
//   3) Composite     — sample curr, apply mild gamma + beat flash, write to
//                      the drawable.
//
// Two offscreen textures ping-pong so each frame reads "previous" and writes
// "current" without sampling its own render target.

// -- uniforms --------------------------------------------------------------

struct MDWarpUniforms {
    float aspect;
    float time;
    float dtFactor;     // dt * 60 — frame-rate independence for `rot`
    float bass;
    float mid;
    float beat;
    float decay;        // 0.96..0.99 — texture fade per frame
    float zoomGain;     // bass coupling into zoom
};

struct MDWaveUniforms {
    float aspect;
    float time;
    float rms;
    float beat;
    float baseRadius;
    float amplitude;
    float thickness;
    int   shape;        // 0=circle, 1=horizontal-line, 2=figure-eight
};

struct MDCompUniforms {
    float aspect;
    float beat;
    float gamma;
    float _pad0;
};

// -- pass 1: warp ----------------------------------------------------------

struct MDWarpOut {
    float4 position [[position]];
    float2 uv;          // [0, 1] texture coord
};

vertex MDWarpOut md_warp_vertex(uint vid [[vertex_id]]) {
    float2 v[6] = { float2(-1,-1), float2(1,-1), float2(-1,1),
                    float2(1,-1),  float2(1,1),  float2(-1,1) };
    MDWarpOut o;
    o.position = float4(v[vid], 0, 1);
    o.uv = v[vid] * 0.5 + 0.5;
    return o;
}

fragment float4 md_warp_fragment(MDWarpOut in [[stage_in]],
                                 constant MDWarpUniforms &u [[buffer(0)]],
                                 texture2d<float> prev [[texture(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);

    // Centred, aspect-corrected coord for the math.
    float2 p = in.uv * 2.0 - 1.0;
    p.x *= u.aspect;

    // Centre drift — a slow elliptical wander so the vortex never sits dead-centre.
    float2 c = 0.10 * float2(sin(u.time * 0.13), cos(u.time * 0.17));

    // Zoom < 1 means we sample from slightly *outside* the current pixel — the
    // image appears to zoom IN over time. Bass and beat tighten the pull.
    float zoom = 1.0 - (0.005 + u.zoomGain * u.bass + 0.040 * u.beat);

    // Slow continuous spin + bassy wobble + per-beat kick.
    float rot = 0.010 * u.dtFactor
              + 0.040 * sin(u.time * 0.30) * u.bass
              + 0.080 * u.beat;
    float cR = cos(rot), sR = sin(rot);

    // Per-pixel sinusoidal warp — what gives Milkdrop its swirling organic feel.
    float warpAmt = 0.015 + 0.025 * u.bass;
    float2 warp = warpAmt * float2(
        sin(p.y * 5.7 + u.time * 1.30),
        cos(p.x * 6.3 + u.time * 1.10));

    float2 q = p - c;
    q = float2(cR * q.x - sR * q.y, sR * q.x + cR * q.y);
    q *= zoom;
    q += c + warp;

    // Back to texture space.
    q.x /= u.aspect;
    float2 prevUV = q * 0.5 + 0.5;

    float3 ret = prev.sample(s, prevUV).rgb;
    ret *= u.decay;
    return float4(ret, 1.0);
}

// -- pass 2: waveform line strip (additive) --------------------------------

struct MDWaveOut {
    float4 position [[position]];
    float  t;            // 0..1 along the curve — used for palette gradient
    float2 local;        // for SDF AA across the strip
};

// Inigo Quilez sdSegment.
static inline float sdSegmentMD(float2 p, float2 a, float2 b) {
    float2 pa = p - a, ba = b - a;
    float h = saturate(dot(pa, ba) / max(dot(ba, ba), 1e-8));
    return length(pa - ba * h);
}

vertex MDWaveOut md_wave_vertex(uint vid [[vertex_id]],
                                uint iid [[instance_id]],
                                constant float2 *waveVerts [[buffer(0)]],
                                constant uint &vertCount [[buffer(1)]],
                                constant MDWaveUniforms &u [[buffer(2)]]) {
    // Each instance is a segment between waveVerts[iid] and waveVerts[iid+1].
    uint i0 = iid;
    uint i1 = min(iid + 1, vertCount - 1);
    float2 a = waveVerts[i0];
    float2 b = waveVerts[i1];

    // Expand the segment to a quad in aspect-corrected pixel space.
    float2 along = b - a;
    along.x *= u.aspect;
    float len = max(length(along), 1e-6);
    float2 dir = along / len;
    float2 nor = float2(-dir.y, dir.x);
    nor.x /= u.aspect;

    float th = u.thickness * (1.0 + u.beat * 2.0);

    float2 quad[6] = { a - nor*th, b - nor*th, a + nor*th,
                       b - nor*th, b + nor*th, a + nor*th };
    float2 localPos[6] = { float2(-1, -1), float2(1, -1), float2(-1, 1),
                           float2( 1, -1), float2(1,  1), float2(-1, 1) };

    MDWaveOut o;
    o.position = float4(quad[vid], 0.0, 1.0);
    o.local = localPos[vid];
    o.t = float(iid) / float(max(1u, vertCount - 1));
    return o;
}

fragment float4 md_wave_fragment(MDWaveOut in [[stage_in]],
                                 constant MDWaveUniforms &u [[buffer(0)]],
                                 texture2d<float> palette [[texture(0)]]) {
    constexpr sampler s(filter::linear);
    // Cheap glow via Gaussian across the strip width — additive blend at the
    // pipeline level lets repeated draws accumulate.
    float d = length(in.local);
    float core = exp(-d * d * 3.0);
    float halo = exp(-d * 1.4) * 0.30;
    float intensity = core + halo;

    float palU = fract(in.t + u.rms * 0.15);
    float3 col = palette.sample(s, float2(palU, 0.5)).rgb;
    col = mix(col, float3(1.0), core * 0.20);
    float3 outCol = col * intensity * (1.0 + 0.5 * u.beat);
    return float4(outCol, intensity);
}

// -- pass 3: composite ----------------------------------------------------

struct MDCompOut {
    float4 position [[position]];
    float2 uv;
};

vertex MDCompOut md_comp_vertex(uint vid [[vertex_id]]) {
    float2 v[6] = { float2(-1,-1), float2(1,-1), float2(-1,1),
                    float2(1,-1),  float2(1,1),  float2(-1,1) };
    MDCompOut o;
    o.position = float4(v[vid], 0, 1);
    o.uv = v[vid] * 0.5 + 0.5;
    return o;
}

fragment float4 md_comp_fragment(MDCompOut in [[stage_in]],
                                 constant MDCompUniforms &u [[buffer(0)]],
                                 texture2d<float> curr [[texture(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float3 c = curr.sample(s, in.uv).rgb;
    c = pow(c, float3(u.gamma));        // mild gamma lift
    c *= 1.0 + 0.4 * u.beat;            // beat brightness flash
    return float4(c, 1.0);
}
