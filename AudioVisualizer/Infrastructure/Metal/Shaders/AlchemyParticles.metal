#include <metal_stdlib>
using namespace metal;

struct Particle { float2 pos; float2 vel; float life; float seed; };

struct AlchemyUniforms { float bass; float dt; float aspect; float time; };

kernel void alchemy_update(device Particle *p [[buffer(0)]],
                           constant AlchemyUniforms &u [[buffer(1)]],
                           uint id [[thread_position_in_grid]]) {
    Particle x = p[id];
    float2 toCenter = -x.pos;
    float r = length(toCenter) + 0.001;
    float2 radial = toCenter / r;
    float push = (u.bass * 1.5 + 0.05) / max(r, 0.05);
    x.vel += -radial * push * u.dt + float2(sin(u.time + x.seed) * 0.02, cos(u.time * 1.3 + x.seed)) * u.dt;
    x.vel *= 0.97;
    x.pos += x.vel * u.dt;
    x.life -= u.dt * 0.3;
    if (x.life <= 0.0 || length(x.pos) > 1.4) {
        x.pos = float2(0.0);
        float angle = x.seed * 6.2831853;
        x.vel = float2(cos(angle), sin(angle)) * (0.2 + u.bass);
        x.life = 1.0;
    }
    p[id] = x;
}

struct AlchemyVertOut {
    float4 position [[position]];
    float life;
};

vertex AlchemyVertOut alchemy_vertex(uint vid [[vertex_id]],
                                     uint iid [[instance_id]],
                                     const device Particle *p [[buffer(0)]],
                                     constant AlchemyUniforms &u [[buffer(1)]]) {
    float2 quad[6] = { float2(-1,-1), float2(1,-1), float2(-1,1),
                       float2(1,-1), float2(1,1), float2(-1,1) };
    float2 v = quad[vid] * 0.01;
    v.x /= u.aspect;
    AlchemyVertOut out;
    out.position = float4(p[iid].pos + v, 0.0, 1.0);
    out.life = clamp(p[iid].life, 0.0, 1.0);
    return out;
}

fragment float4 alchemy_fragment(AlchemyVertOut in [[stage_in]],
                                 texture2d<float> palette [[texture(0)]]) {
    constexpr sampler s(filter::linear);
    float3 col = palette.sample(s, float2(in.life, 0.5)).rgb;
    return float4(col * in.life, in.life);
}
