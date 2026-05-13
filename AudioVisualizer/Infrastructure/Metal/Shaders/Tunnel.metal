#include <metal_stdlib>
using namespace metal;

struct TunnelUniforms {
    float time;
    float aspect;
    float rms;
    float beat;
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
    float depth = 0.6 / max(r, 0.001);
    float twist = a / 3.14159265 + 0.5;
    // Audio-reactive bands flowing inward.
    float band = fract(depth - u.time * (0.5 + u.rms * 4.0));
    float rings = smoothstep(0.45, 0.5, band) - smoothstep(0.5, 0.55, band);
    float swirl = 0.5 + 0.5 * sin(twist * 12.0 + u.time * 1.5);
    // Vignette + beat flash.
    float vignette = smoothstep(1.6, 0.2, r);
    float pulse = 1.0 + 0.6 * u.beat;
    float intensity = (rings * 0.9 + swirl * 0.15) * vignette * pulse;
    float4 col = palette.sample(s, float2(saturate(intensity + u.rms * 0.4), 0.5));
    col.rgb *= intensity * 1.4;
    col.a = 1.0;
    return col;
}
