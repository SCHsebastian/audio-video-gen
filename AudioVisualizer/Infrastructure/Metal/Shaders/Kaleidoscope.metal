#include <metal_stdlib>
using namespace metal;

// Canonical kaleidoscope: fold polar coords into one mirrored wedge, then
// sample a domain-warped FBM field in the folded coordinate so the result
// inherits 2N-fold dihedral symmetry. Bass squeezes the pattern, mid drives
// rotation, treble adds high-freq grain, beats flash and briefly double N.

struct KUniforms {
    float aspect;
    float time;
    float rms;
    float bass;
    float mid;
    float treble;
    float beat;          // 0..1 beat envelope (decays in scene)
    float rotate;        // CPU-integrated rotation angle, wrapped
    int   sectors;       // base N — 6/8/10/12; doubled briefly on beat
    float _pad0;
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

// -- noise helpers ----------------------------------------------------------

static inline float hash21(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

static inline float vnoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    float a = hash21(i);
    float b = hash21(i + float2(1, 0));
    float c = hash21(i + float2(0, 1));
    float d = hash21(i + float2(1, 1));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

static inline float fbm(float2 p) {
    float s = 0.0, a = 0.5;
    for (int i = 0; i < 4; i++) { s += a * vnoise(p); p *= 2.07; a *= 0.5; }
    return s;
}

// -- main -------------------------------------------------------------------

fragment float4 kal_fragment(KOut in [[stage_in]],
                             constant KUniforms &u [[buffer(1)]],
                             texture2d<float> palette [[texture(0)]]) {
    constexpr sampler s(filter::linear);

    float2 uv = in.ndc;
    uv.x *= u.aspect;
    float r = length(uv);
    float th = atan2(uv.y, uv.x) + u.rotate;

    // Beat-doubled N — a hard step ensures N stays integer at every instant
    // so wedge boundaries always meet themselves (no strobing seams).
    int Nbase = max(u.sectors, 4);
    int Neff = Nbase + Nbase * int(step(0.5, u.beat));
    float slice = M_PI_F / float(Neff);

    // Branchless canonical fold — `mod(θ + slice, 2*slice) - slice` then |·|.
    float th2 = fmod(th + slice + 6.28318530718, 2.0 * slice);
    float thF = fabs(th2 - slice);
    float2 p = r * float2(cos(thF), sin(thF));

    // Domain-warped FBM in the folded coord.
    float freq = 2.0 * (1.0 + u.bass * 0.8);
    float2 q = p * freq;
    q += 0.5 * float2(fbm(q + u.time * 0.07),
                      fbm(q + 7.7 + u.time * 0.05));
    float f = fbm(q + u.time * 0.10);
    // Treble-driven grain.
    f += u.treble * 0.15 * (hash21(p * 30.0 + u.time * 8.0) - 0.5);

    // Palette sampled by the noise value + slow drift + bass.
    float palU = fract(f + u.time * 0.05 + u.bass * 0.10);
    float3 col = palette.sample(s, float2(palU, 0.5)).rgb;
    col *= 1.0 + u.rms * 0.20;
    col += u.beat * 0.18;       // brightness flash

    // Centre hole: noise is dominated by a single high-amp speckle at r→0.
    float centerMask = smoothstep(0.04, 0.10, r);
    // Hot core that pulses with bass.
    float3 hotCore = (1.0 - centerMask) * (0.5 + 0.8 * u.bass)
                   * float3(1.0, 0.95, 0.85);
    col = col * centerMask + hotCore;

    // Soft outer vignette so the symmetry floats on black.
    col *= smoothstep(1.20, 0.35, r);

    return float4(col, 1.0);
}
