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
    float attractorSpeedX;
    float attractorSpeedY;
    float attractorAmpX;
    float attractorAmpY;
    float curlScale;
    float swirlBias;
    float hueShift;
    float beatTriggered;   // 1.0 only on the frame a beat first fires
    float _pad1;
};

// -- noise helpers ---------------------------------------------------------

static inline float hash21(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

static inline float hash31(float3 p) {
    p = fract(p * float3(0.1031, 0.1030, 0.0973));
    p += dot(p, p.yzx + 33.33);
    return fract((p.x + p.y) * p.z);
}

// 3D value noise — pass `time` as the Z slice so the noise field morphs in
// place instead of just translating across the plane.
static inline float vnoise3(float3 p) {
    float3 i = floor(p);
    float3 f = fract(p);
    float3 u = f * f * (3.0 - 2.0 * f);
    float a = hash31(i + float3(0,0,0));
    float b = hash31(i + float3(1,0,0));
    float c = hash31(i + float3(0,1,0));
    float d = hash31(i + float3(1,1,0));
    float e = hash31(i + float3(0,0,1));
    float f1 = hash31(i + float3(1,0,1));
    float g = hash31(i + float3(0,1,1));
    float h = hash31(i + float3(1,1,1));
    float x0 = mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
    float x1 = mix(mix(e, f1, u.x), mix(g, h, u.x), u.y);
    return mix(x0, x1, u.z);
}

// 3-octave fBm in the (x, y, z=time) plane.
static inline float fbm3(float3 p) {
    float s = 0.0, a = 0.5;
    for (int i = 0; i < 3; i++) { s += a * vnoise3(p); p *= 2.03; a *= 0.55; }
    return s;
}

// Divergence-free 2D curl noise built from fBm — gives swirly, fluid motion
// with no point attractors. Time advances through the 3rd noise coordinate
// so the field "morphs" instead of "scrolls".
static inline float2 curl(float2 p, float t) {
    const float eps = 0.07;
    float n1 = fbm3(float3(p + float2(0, eps), t));
    float n2 = fbm3(float3(p - float2(0, eps), t));
    float n3 = fbm3(float3(p + float2(eps, 0), t));
    float n4 = fbm3(float3(p - float2(eps, 0), t));
    return float2((n1 - n2), -(n3 - n4)) / (2.0 * eps);
}

// Inigo Quilez cosine palette — cheap, hue-rich gradients without a texture.
static inline float3 iqPalette(float t, float3 d) {
    return float3(0.5) + float3(0.5) * cos(6.2831853 * (t + d));
}

// -- compute ---------------------------------------------------------------

kernel void alchemy_update(device Particle *p [[buffer(0)]],
                           constant AlchemyUniforms &u [[buffer(1)]],
                           uint id [[thread_position_in_grid]]) {
    Particle x = p[id];
    const float t = u.time;
    const float dt = u.dt;

    float2 attractor = float2(sin(t * u.attractorSpeedX + 0.7) * u.attractorAmpX,
                              sin(t * u.attractorSpeedY + 1.3) * u.attractorAmpY);
    float2 to = attractor - x.pos;
    float  r  = max(length(to), 0.05);
    float2 radial = to / r;
    float2 tangent = float2(-radial.y, radial.x);

    // Mid couples to *curl frequency* now — visibly changes the texture of
    // the swirl, not just its strength.
    const float noiseTimeRate = 0.15;
    float2 q = x.pos * (u.curlScale * (1.0 + u.mid * 0.8)) + x.seed * 7.3;
    float2 swirl = curl(q, t * noiseTimeRate);

    float forceScale = 0.9 + 2.0 * u.bass + 1.5 * u.beat;
    float attractStrength = 0.30 + u.bass * 1.4;

    float2 accel = radial * attractStrength * (0.22 / (r + 0.25))
                 + tangent * (u.swirlBias + u.bass * 1.2)
                 + swirl * 1.4 * forceScale;

    x.vel += accel * dt;
    // Drag drives off *bass*, not beat — heavier bass loosens the cloud,
    // beats deliver punctuation via the impulse below.
    float dragPerSec = mix(0.985, 0.92, u.bass);
    x.vel *= pow(dragPerSec, dt * 60.0);

    // Beat impulse — one instantaneous kick on the trigger frame, not scaled
    // by dt (otherwise it shrinks at high frame rates).
    if (u.beatTriggered > 0.5 && u.beat > 0.25) {
        x.vel += radial * 0.9 * u.beat * sin(x.seed * 31.4);
    }

    // Velocity cap so a sequence of beats can't fling particles forever.
    const float vmax = 2.5;
    float vlen = length(x.vel);
    if (vlen > vmax) x.vel *= (vmax / vlen);

    x.pos += x.vel * dt;
    x.life -= dt * (0.18 + u.treble * 0.4);

    if (x.life <= 0.0 || length(x.pos) > 1.6) {
        float a = x.seed * 6.2831853 + t * 0.7;
        float2 dir = float2(cos(a), sin(a));
        float spawnR = 0.55 + 0.40 * hash21(float2(x.seed, t));
        x.pos = attractor + dir * spawnR;
        x.vel = float2(-dir.y, dir.x) * (0.25 + u.bass * 1.0);
        x.life = 0.85 + 0.30 * hash21(float2(t, x.seed));
    }
    p[id] = x;
}

// -- render ----------------------------------------------------------------

struct AlchemyVertOut {
    float4 position [[position]];
    float2 uv;
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
    float size = clamp(0.008 + speed * 0.012 + u.beat * 0.006, 0.005, 0.045);

    float2 quad[6] = { float2(-1,-1), float2(1,-1), float2(-1,1),
                       float2(1,-1), float2(1,1), float2(-1,1) };
    float2 offset = quad[vid] * size;
    offset.x /= max(0.0001, u.aspect);

    AlchemyVertOut o;
    o.position = float4(q.pos + offset, 0.0, 1.0);
    o.uv = quad[vid];
    o.life = clamp(q.life, 0.0, 1.0);
    float angle = atan2(q.pos.y, q.pos.x) / 6.2831853 + 0.5;
    o.hue = fract(angle * 1.3 + (1.0 - o.life) * 0.35
                  + u.bass * 0.25 + q.seed * 0.15 + u.hueShift);
    float env = sin(o.life * 3.14159265);
    o.intensity = env * (0.30 + u.beat * 0.45);
    return o;
}

fragment float4 alchemy_fragment(AlchemyVertOut in [[stage_in]]) {
    float d = length(in.uv);
    if (d > 1.0) discard_fragment();
    float core = exp(-d * d * 6.0);
    float halo = exp(-d * 2.5) * 0.35;
    float a = (core + halo) * in.intensity;

    // IQ cosine palette in fragment — texture-free, hue-rich. The phase
    // offsets give an even rainbow distribution.
    float3 col = iqPalette(in.hue, float3(0.00, 0.33, 0.67));
    col = mix(col, float3(1.0), core * 0.18);
    return float4(col * a, a);
}
