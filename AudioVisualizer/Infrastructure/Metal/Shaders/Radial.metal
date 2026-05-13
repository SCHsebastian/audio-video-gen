#include <metal_stdlib>
using namespace metal;

struct RadialUniforms {
    float aspect;
    float time;
    int   barCount;
    float rms;
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

// Spectrum bars laid out around a full circle. Heights[i] in [0, 1] sets the
// outer radius of bar i. Anti-aliased via smoothstep on both radial and
// angular edges; soft inner glow rim adds depth without strobing on beats.
fragment float4 radial_fragment(RVertOut in            [[stage_in]],
                                constant float *heights [[buffer(0)]],
                                constant RadialUniforms &u [[buffer(1)]],
                                texture2d<float> palette [[texture(0)]]) {
    constexpr sampler s(filter::linear);

    // Aspect-correct coordinates so the ring is round in non-square windows.
    float2 p = in.ndc;
    p.x *= u.aspect;

    float dist  = length(p);
    float angle = atan2(p.y, p.x);
    const float TWO_PI = 6.28318530718;
    if (angle < 0) angle += TWO_PI;

    // Slow ambient rotation so the figure doesn't feel locked.
    float rot = u.time * 0.08;
    float a = fmod(angle + rot, TWO_PI);

    const float innerR  = 0.22;
    const float maxBarH = 0.62;
    int n = u.barCount;
    if (n < 1) n = 1;

    float slice = TWO_PI / float(n);
    int   bar   = int(floor(a / slice));
    if (bar < 0) bar = 0;
    if (bar >= n) bar = n - 1;

    float h      = heights[bar];
    float outerR = innerR + h * maxBarH;

    // Angular distance to bar center (handles wrap at 2π).
    float centerA = (float(bar) + 0.5) * slice;
    float angDist = fabs(a - centerA);
    if (angDist > 3.14159265) angDist = TWO_PI - angDist;

    const float gapFrac  = 0.16;                              // 16% gap each side
    float halfWidth      = slice * (0.5 - gapFrac);
    float aa             = fwidth(angDist) + 1e-4;
    float angularMask    = 1.0 - smoothstep(halfWidth - aa, halfWidth + aa, angDist);

    // Radial mask — anti-aliased on both the inner ring and the bar tip.
    float dAA            = fwidth(dist) + 1e-4;
    float innerMask      = smoothstep(innerR - dAA, innerR + dAA, dist);
    float outerMask      = 1.0 - smoothstep(outerR - dAA, outerR + dAA, dist);
    float fill           = innerMask * outerMask * angularMask;

    // Palette samples from bar center radially outward.
    float palU = clamp((dist - innerR) / maxBarH, 0.0, 1.0);
    float3 base = palette.sample(s, float2(palU, 0.5)).rgb;

    // Outer soft glow — small, additive, ignores the angular mask so the
    // whole figure has a subtle halo.
    float glowD = dist - outerR;
    float glow  = exp(-fabs(glowD) * 14.0) * 0.45 * angularMask;

    // Inner luminous core ring (just outside innerR) for that "audio
    // halo" feel without flashes.
    float core = exp(-fabs(dist - innerR) * 22.0) * 0.50;

    float3 col = base * fill + base * glow + float3(1.0) * core * 0.25;
    float  alpha = fill + glow + core * 0.6;
    return float4(col * alpha, alpha);
}
