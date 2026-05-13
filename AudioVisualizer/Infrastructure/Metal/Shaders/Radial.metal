#include <metal_stdlib>
using namespace metal;

// Canonical radial spectrum — log-frequency bars laid out around half of
// a circle, mirrored across the vertical axis so the figure reads as a
// designed wheel. Rainbow palette wraps angularly (bass at the top, treble
// at the bottom). A separate beat ring at `r_inner` breathes with each kick.

struct RadialUniforms {
    float aspect;
    float time;
    int   barCount;        // rendered half-count, typically 64
    float rms;
    float beat;            // 0..1 beat envelope (decays in scene)
    float beatAge;         // 0..1 ramp since last beat (for rotation kick)
    float _pad0;
    float _pad1;
};

struct RVertOut {
    float4 position [[position]];
    float2 ndc;
};

vertex RVertOut radial_vertex(uint vid [[vertex_id]]) {
    float2 verts[6] = { float2(-1,-1), float2(1,-1), float2(-1,1),
                        float2(1,-1),  float2(1,1),  float2(-1,1) };
    RVertOut o;
    o.position = float4(verts[vid], 0, 1);
    o.ndc = verts[vid];
    return o;
}

fragment float4 radial_fragment(RVertOut in [[stage_in]],
                                constant float *heights [[buffer(0)]],
                                constant RadialUniforms &u [[buffer(1)]],
                                texture2d<float> palette [[texture(0)]]) {
    constexpr sampler s(filter::linear);

    // Aspect-correct + mirror across the vertical axis (|p.x|).
    float2 p = in.ndc;
    p.x *= u.aspect;
    float2 q = float2(fabs(p.x), p.y);
    float dist = length(q);

    // Continuous rotation (slow) plus a per-beat kick that decays.
    float rotKick = 0.15 * exp(-2.5 * u.beatAge);
    float rot = u.time * 0.05 + rotKick;
    // 0 at the top, π at the bottom. Mirror is already baked via |p.x|.
    float ang = atan2(q.x, -q.y) + rot;
    ang = fmod(ang + 6.28318530718, 3.14159265);

    int n = max(u.barCount, 8);
    float slice = 3.14159265 / float(n);
    int   bar   = clamp(int(floor(ang / slice)), 0, n - 1);

    float h      = heights[bar];
    const float innerR = 0.25;
    const float maxBarH = 0.55;
    float outerR = innerR + h * maxBarH;

    // AA angular wedge (gap between bars).
    float centerA = (float(bar) + 0.5) * slice;
    float angDist = fabs(ang - centerA);
    const float gapFrac = 0.18;
    float halfW = slice * (0.5 - gapFrac);
    float aaA = fwidth(angDist) + 1e-4;
    float ang01 = 1.0 - smoothstep(halfW - aaA, halfW + aaA, angDist);

    // AA radial annulus.
    float aaR = fwidth(dist) + 1e-4;
    float innerMask = smoothstep(innerR - aaR, innerR + aaR, dist);
    float outerMask = 1.0 - smoothstep(outerR - aaR, outerR + aaR, dist);
    float bar01 = ang01 * innerMask * outerMask;

    // Palette wraps angularly (rainbow around) — same hue on both halves so
    // the figure reads as intentionally symmetric.
    float palU = fract(float(bar) / float(n));
    float3 base = palette.sample(s, float2(palU, 0.5)).rgb;
    float3 barCol = base * (0.45 + 0.55 * h);

    // Beat ring at r_inner — pulses outward + brightens on each beat. Not
    // gated by angular mask so the whole figure breathes together.
    float ringR = innerR + 0.05 * u.beat;
    float ringW = 0.006 + 0.012 * u.beat;
    float ringD = fabs(dist - ringR);
    float ring = exp(-ringD * ringD / max(ringW * ringW, 1e-6));
    float3 ringCol = mix(float3(1.0), palette.sample(s, float2(0.5, 0.5)).rgb, 0.40)
                   * ring * (0.30 + 0.70 * u.beat);

    // Outer faint glow that follows the bar tip.
    float glow = exp(-fabs(dist - outerR) * 14.0) * 0.35 * ang01;

    float3 col = barCol * bar01 + base * glow + ringCol;
    float  a   = bar01 + glow + ring * 0.6;
    return float4(col, a);
}
