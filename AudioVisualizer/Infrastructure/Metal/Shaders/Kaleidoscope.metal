#include <metal_stdlib>
using namespace metal;

struct KUniforms {
    float aspect;
    float time;
    float rms;
    float bass;
    int   sectors;          // even integer; 6/8/12 are the nice ones
    float spin;             // global rotation phase
};

struct KOut {
    float4 position [[position]];
    float2 ndc;
};

vertex KOut kal_vertex(uint vid [[vertex_id]]) {
    float2 v[6] = { float2(-1,-1), float2(1,-1), float2(-1,1),
                    float2(1,-1),  float2(1,1),  float2(-1,1) };
    KOut o;
    o.position = float4(v[vid], 0, 1);
    o.ndc = v[vid];
    return o;
}

// Kaleidoscope. Fold polar coordinates into a wedge of width 2π/sectors,
// reflect across the wedge boundaries, then sample a procedural color field.
// The folded coordinate naturally gives N-fold mirror symmetry.
fragment float4 kal_fragment(KOut in [[stage_in]],
                             constant KUniforms &u [[buffer(1)]],
                             texture2d<float> palette [[texture(0)]]) {
    constexpr sampler s(filter::linear);
    float2 p = in.ndc;
    p.x *= u.aspect;

    float r = length(p);
    float a = atan2(p.y, p.x) + u.spin + u.time * 0.06;

    const float TWO_PI = 6.28318530718;
    float wedge = TWO_PI / float(max(u.sectors, 4));
    a = fmod(a + TWO_PI, wedge);
    if (a > wedge * 0.5) a = wedge - a;     // mirror across the wedge centre

    // Folded coords.
    float2 fp = float2(cos(a), sin(a)) * r;

    // Procedural pattern in the folded space — concentric rings + radial bands
    // both modulated by audio so the figure breathes.
    float rings = 0.5 + 0.5 * sin(r * (10.0 + u.bass * 6.0) - u.time * 1.3);
    float bands = 0.5 + 0.5 * sin(a * 18.0 + u.time * 0.9);
    float field = mix(rings, bands, 0.5 + 0.5 * sin(u.time * 0.4));

    // A subtle distance falloff so the center stays bright.
    float core = exp(-r * 1.4);
    float palU = clamp(field * 0.7 + core * 0.3 + u.rms * 0.1, 0.0, 1.0);
    float3 col = palette.sample(s, float2(palU, 0.5)).rgb;
    return float4(col, 1.0);
}
