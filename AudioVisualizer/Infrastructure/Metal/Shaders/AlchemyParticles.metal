#include <metal_stdlib>
using namespace metal;

struct Particle { float2 pos; float2 vel; float life; float seed; };

struct AlchemyUniforms {
    float bass;
    float mid;
    float treble;
    float beat;
    float dt;
    float aspect;
    float time;
    float _pad;
};

// --- small noise helpers --------------------------------------------------

static inline float hash21(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

static inline float vnoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float a = hash21(i);
    float b = hash21(i + float2(1, 0));
    float c = hash21(i + float2(0, 1));
    float d = hash21(i + float2(1, 1));
    float2 u = f * f * (3.0 - 2.0 * f);   // smoothstep
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

// Stream function whose curl is divergence-free — gives swirling, organic motion.
static inline float2 curl(float2 p, float t) {
    const float eps = 0.08;
    float n1 = vnoise(p + float2(0, eps) + float2(t * 0.15, 0));
    float n2 = vnoise(p - float2(0, eps) + float2(t * 0.15, 0));
    float n3 = vnoise(p + float2(eps, 0) + float2(0, t * 0.17));
    float n4 = vnoise(p - float2(eps, 0) + float2(0, t * 0.17));
    return float2((n1 - n2), -(n3 - n4)) / (2.0 * eps);
}

// --- compute --------------------------------------------------------------

kernel void alchemy_update(device Particle *p [[buffer(0)]],
                           constant AlchemyUniforms &u [[buffer(1)]],
                           uint id [[thread_position_in_grid]]) {
    Particle x = p[id];

    // Slow attractor wandering on a Lissajous figure, pulsing with bass+beat.
    float t = u.time;
    float2 attractor = float2(sin(t * 0.31 + 0.7) * 0.55,
                              sin(t * 0.41) * 0.45);
    float attractStrength = 0.6 + u.bass * 2.5 + u.beat * 1.8;

    float2 to = attractor - x.pos;
    float r = max(length(to), 0.05);
    float2 radial = to / r;

    // Curl-noise flow field — driven by treble for higher-frequency swirl.
    float2 q = x.pos * (1.6 + u.treble * 1.2) + x.seed * 7.3;
    float2 swirl = curl(q, t) * (0.9 + u.mid * 2.0);

    // Tangential bias around the attractor so particles orbit instead of crashing in.
    float2 tangent = float2(-radial.y, radial.x);

    float2 accel = radial * attractStrength * (0.3 / (r + 0.2))
                 + tangent * (1.2 + u.bass * 1.5)
                 + swirl * 1.4;

    x.vel += accel * u.dt;
    x.vel *= mix(0.985, 0.93, u.beat);   // beats cause a brief slowdown → sparkle

    // Beat radial burst — gentle, only when energy is high.
    if (u.beat > 0.4) {
        x.vel += radial * u.beat * 0.6 * u.dt * sin(x.seed * 31.4);
    }

    x.pos += x.vel * u.dt;
    x.life -= u.dt * (0.18 + u.treble * 0.4);

    // Respawn near the attractor with a tangential kick so trails form.
    if (x.life <= 0.0 || length(x.pos) > 1.6) {
        float a = x.seed * 6.2831853 + t * 0.7;
        float2 dir = float2(cos(a), sin(a));
        x.pos = attractor + dir * (0.02 + 0.04 * hash21(float2(x.seed, t)));
        x.vel = float2(-dir.y, dir.x) * (0.35 + u.bass * 1.2);
        x.life = 0.85 + 0.3 * hash21(float2(t, x.seed));
    }
    p[id] = x;
}

// --- render ---------------------------------------------------------------

struct AlchemyVertOut {
    float4 position [[position]];
    float2 uv;           // sprite-local in [-1, 1]
    float  life;
    float  hue;
    float  intensity;
};

vertex AlchemyVertOut alchemy_vertex(uint vid [[vertex_id]],
                                     uint iid [[instance_id]],
                                     const device Particle *p [[buffer(0)]],
                                     constant AlchemyUniforms &u [[buffer(1)]]) {
    Particle q = p[iid];
    float speed = length(q.vel);
    // Size scales with speed and beat; clamp so very fast particles don't blow up.
    float size = clamp(0.008 + speed * 0.012 + u.beat * 0.006, 0.005, 0.045);

    float2 quad[6] = { float2(-1,-1), float2(1,-1), float2(-1,1),
                       float2(1,-1), float2(1,1), float2(-1,1) };
    float2 offset = quad[vid] * size;
    offset.x /= max(0.0001, u.aspect);

    AlchemyVertOut o;
    o.position = float4(q.pos + offset, 0.0, 1.0);
    o.uv = quad[vid];
    o.life = clamp(q.life, 0.0, 1.0);
    // Hue: mix angle around center, life, and a touch of audio energy.
    float angle = atan2(q.pos.y, q.pos.x) / 6.2831853 + 0.5;
    o.hue = fract(angle * 1.3 + (1.0 - o.life) * 0.35 + u.bass * 0.25 + q.seed * 0.15);
    // Intensity envelope: brighter at mid-life, dim at spawn and death.
    float env = sin(o.life * 3.14159265);
    o.intensity = env * (0.65 + u.beat * 0.9);
    return o;
}

fragment float4 alchemy_fragment(AlchemyVertOut in [[stage_in]],
                                 texture2d<float> palette [[texture(0)]]) {
    constexpr sampler s(filter::linear);
    float d = length(in.uv);
    if (d > 1.0) discard_fragment();
    // Soft circular falloff — gaussian-ish core + halo.
    float core = exp(-d * d * 6.0);
    float halo = exp(-d * 2.5) * 0.35;
    float a = (core + halo) * in.intensity;

    float3 col = palette.sample(s, float2(in.hue, 0.5)).rgb;
    // Slight white-hot core on bright particles.
    col = mix(col, float3(1.0), core * 0.35);
    return float4(col * a, a);
}
