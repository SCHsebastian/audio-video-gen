#include <metal_stdlib>
using namespace metal;

struct BarsUniforms {
    float aspect;
    float time;
    int barCount;
};

struct BarsOut {
    float4 position [[position]];
    float2 local;     // [-1, 1] across the bar quad
    float  height;    // 0..1 envelope of this bar
    float  size;      // quad height in NDC (for SDF aa)
};

vertex BarsOut bars_vertex(uint vid [[vertex_id]],
                           uint iid [[instance_id]],
                           constant float *heights [[buffer(0)]],
                           constant BarsUniforms &u [[buffer(1)]]) {
    float w = 2.0 / float(u.barCount);
    float gap = 0.10;                                  // 10% gap on each side
    float x0 = -1.0 + w * float(iid) + w * (gap * 0.5);
    float x1 = x0 + w * (1.0 - gap);
    float h = max(heights[iid], 0.006);                // visible idle line
    // Centre the bars vertically so they grow up *and* down (mirror).
    // Bar half-height in NDC; clamped so it never overruns the canvas.
    float halfH = min(0.96, h);
    float y0 = -halfH;
    float yTop = halfH;
    float pad = 0.04;
    float y1 = min(1.0, yTop + pad);
    y0 = max(-1.0, y0 - pad);

    float2 verts[6] = { float2(x0,y0), float2(x1,y0), float2(x0,y1),
                        float2(x1,y0), float2(x1,y1), float2(x0,y1) };
    float2 locals[6] = { float2(-1,-1), float2(1,-1), float2(-1,1),
                         float2(1,-1),  float2(1,1),  float2(-1,1) };

    BarsOut o;
    o.position = float4(verts[vid], 0.0, 1.0);
    o.local = locals[vid];
    o.height = h;
    o.size = (y1 - y0) * 0.5;
    return o;
}

// SDF of a rounded box centred at origin with half-size b and corner radius r.
static inline float sdRoundBox(float2 p, float2 b, float r) {
    float2 q = abs(p) - b + r;
    return length(max(q, float2(0))) + min(max(q.x, q.y), 0.0) - r;
}

fragment float4 bars_fragment(BarsOut in [[stage_in]],
                              texture2d<float> palette [[texture(0)]]) {
    constexpr sampler s(filter::linear);

    // Mirror layout: in.local.y is [-1, 1] across the padded full-height quad.
    // The bar fills the centre; take |y| so colour symmetry mirrors top↔bottom.
    float yAbs = abs(in.local.y);
    float pad_frac = 0.04 / max(0.001, in.size);
    float yBar = yAbs / (1.0 + pad_frac);              // 0..1 from centre outwards
    float2 p = float2(in.local.x, yBar * 2.0 - 1.0);   // SDF wants [-1, 1]

    float d = sdRoundBox(p, float2(0.85, 1.0), 0.35);
    float aa = fwidth(d) + 0.001;
    float fill = 1.0 - smoothstep(-aa, aa, d);
    float glow = exp(-max(d, 0.0) * 6.0) * 0.55;

    // Gradient brightens toward the centre (axis of symmetry).
    float centreT = 1.0 - yBar;                         // 1 at centre, 0 at tip
    float palU = clamp(in.height * 0.55 + centreT * 0.45, 0.0, 1.0);
    float3 base = palette.sample(s, float2(palU, 0.5)).rgb;

    // Highlight ridge at the very tip (top or bottom — symmetric).
    float ridge = smoothstep(0.92, 0.99, yBar) * (1.0 - smoothstep(1.0, 1.04, yBar));
    float3 col = base * (0.6 + 0.6 * centreT) + float3(1.0) * ridge * 0.5;

    float a = fill + glow * (1.0 - fill);
    return float4(col * a, a);
}
