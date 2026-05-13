#include <metal_stdlib>
using namespace metal;

struct TunnelUniforms {
    float time;
    float aspect;
    float rms;
    float beat;
    float twist;       // ring twist frequency (per turn)
    float depth;       // depth-curve coefficient
    float tight;       // ring tightness (band width scaler)
    float _pad;
};

struct TVertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex TVertexOut tunnel_vertex(uint vid [[vertex_id]]) {
    float2 verts[6] = { float2(-1,-1), float2( 1,-1), float2(-1, 1),
                        float2( 1,-1), float2( 1, 1), float2(-1, 1) };
    TVertexOut o;
    o.position = float4(verts[vid], 0.0, 1.0);
    o.uv = verts[vid];
    return o;
}

fragment float4 tunnel_fragment(TVertexOut in [[stage_in]],
                                constant TunnelUniforms &u [[buffer(0)]],
                                texture2d<float> palette [[texture(0)]]) {
    constexpr sampler s(filter::linear);
    float2 p = in.uv;
    p.x *= u.aspect;
    float r = length(p);
    float a = atan2(p.y, p.x);
    // Tunnel coordinates: depth ~ 1/r, twist ~ a + time.
    float depth = u.depth / max(r, 0.001);
    float twist = a / 3.14159265 + 0.5;
    float band = fract(depth - u.time * (0.35 + u.rms * 2.5));
    float w = 0.12 / max(0.4, u.tight);
    float ring1 = smoothstep(0.5 - w, 0.5, band) - smoothstep(0.5, 0.5 + w, band);
    float ring2 = exp(-pow((band - 0.5) * 3.0 * u.tight, 2.0)) * 0.6;
    float rings = ring1 * 0.75 + ring2 * 0.55;
    float swirl = 0.5 + 0.5 * sin(twist * u.twist + u.time * 0.9);
    // Soft vignette + beat lift.
    float vignette = smoothstep(1.8, 0.15, r);
    float pulse = 1.0 + 0.5 * u.beat;
    float intensity = (rings * 0.95 + swirl * 0.10) * vignette * pulse;
    float4 col = palette.sample(s, float2(saturate(intensity + u.rms * 0.4), 0.5));
    col.rgb *= intensity * 1.4;
    col.a = 1.0;
    return col;
}
