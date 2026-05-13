#include <metal_stdlib>
using namespace metal;

struct MDUniforms {
    float aspect;
    float time;
    float rms;
    float bass;
    float warp;
    float swirl;
};

struct MDOut {
    float4 position [[position]];
    float2 ndc;
};

vertex MDOut md_vertex(uint vid [[vertex_id]]) {
    float2 v[6] = { float2(-1,-1), float2(1,-1), float2(-1,1),
                    float2(1,-1),  float2(1,1),  float2(-1,1) };
    MDOut o;
    o.position = float4(v[vid], 0, 1);
    o.ndc = v[vid];
    return o;
}

// Simplified Milkdrop / Winamp tribute. Procedural fluid-like swirling pattern
// using domain-warped layered sine waves — no actual frame feedback (avoids
// ping-pong textures), but you get the same "moving lava" vibe.
static inline float hash(float2 p) {
    return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453);
}

static inline float vnoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    float a = hash(i);
    float b = hash(i + float2(1, 0));
    float c = hash(i + float2(0, 1));
    float d = hash(i + float2(1, 1));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

static inline float fbm(float2 p) {
    float s = 0.0, a = 0.5;
    for (int i = 0; i < 4; i++) { s += a * vnoise(p); p *= 2.07; a *= 0.5; }
    return s;
}

fragment float4 md_fragment(MDOut in [[stage_in]],
                            constant MDUniforms &u [[buffer(1)]],
                            texture2d<float> palette [[texture(0)]]) {
    constexpr sampler s(filter::linear);
    float2 p = in.ndc;
    p.x *= u.aspect;
    float t = u.time * 0.08;

    // Two layers of domain warp — like a fluid being stirred.
    float2 q = float2(fbm(p * 1.3 + float2(t, -t * 1.3)),
                      fbm(p * 1.3 + float2(-t * 1.1, t * 0.7)));
    float2 r = float2(fbm(p * 1.7 + q * (1.0 + u.warp) + float2(t * 0.6, 0)),
                      fbm(p * 1.7 + q * (1.0 + u.warp) + float2(0, t * 0.5)));
    float n = fbm(p * 2.0 + r * (1.4 + u.bass * 2.0) + t);

    // Swirl: rotate UVs around the origin by a small angle that grows with
    // bass — gives the iconic Milkdrop "vortex" feel.
    float ang = u.swirl + u.bass * 1.8 + t * 0.4;
    float ca = cos(ang), sa = sin(ang);
    float2 ps = float2(ca * p.x - sa * p.y, sa * p.x + ca * p.y);
    float swirl = fbm(ps * 1.0 + r * 0.6 + t * 0.7);

    float v = clamp(0.45 * n + 0.55 * swirl, 0.0, 1.0);
    // Map the value through the palette; bass and RMS push toward the bright
    // end of the palette without ever clipping to white.
    float palU = clamp(v * 0.65 + u.rms * 0.10 + u.bass * 0.20, 0.0, 1.0);
    float3 col = palette.sample(s, float2(palU, 0.5)).rgb;
    return float4(col, 1.0);
}
