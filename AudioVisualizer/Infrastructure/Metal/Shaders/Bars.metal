#include <metal_stdlib>
using namespace metal;

// Canonical Winamp / Windows-Media-Player bars view.
//
// Bars stand on a virtual floor at NDC y = -0.96 and grow upward; their
// heights come from a CPU-side log-frequency / dB-scaled / asymmetric-smoothed
// pipeline (see `vk_bars_process`). A second instanced draw paints a thin
// horizontal "peak cap" slab at the floating peak position.

struct BarsUniforms {
    float aspect;
    float time;
    int   barCount;
    float beatFlash;     // 0..1, decays in the scene after a beat
};

struct BarsOut {
    float4 position [[position]];
    float  palU;        // 0 at floor, 1 at tip — vertical gradient
    float  isPeak;      // 0 for body, 1 for cap (toggles fragment styling)
};

constant float kFloorY  = -0.96;
constant float kCeilFrac = 0.92;   // body never overruns 92% of canvas above floor
constant float kBarGapFrac = 0.15; // 15% of slot is empty space

// --- Bar body ------------------------------------------------------------

vertex BarsOut bars_vertex(uint vid [[vertex_id]],
                           uint iid [[instance_id]],
                           constant float *heights [[buffer(0)]],
                           constant BarsUniforms &u [[buffer(2)]]) {
    const float slot = 2.0 / float(u.barCount);
    const float x0 = -1.0 + slot * float(iid) + slot * (kBarGapFrac * 0.5);
    const float x1 = x0 + slot * (1.0 - kBarGapFrac);

    const float h = max(heights[iid], 0.004);            // visible idle line
    const float topY = kFloorY + 2.0 * kCeilFrac * h;

    const float2 verts[6] = {
        float2(x0, kFloorY), float2(x1, kFloorY), float2(x0, topY),
        float2(x1, kFloorY), float2(x1, topY),   float2(x0, topY)
    };
    const float yLocal[6] = { 0.0, 0.0, 1.0,  0.0, 1.0, 1.0 };

    BarsOut o;
    o.position = float4(verts[vid], 0.0, 1.0);
    o.palU = yLocal[vid];
    o.isPeak = 0.0;
    return o;
}

// --- Peak cap (thin slab anchored at the falling peak position) ----------

vertex BarsOut bars_peak_vertex(uint vid [[vertex_id]],
                                uint iid [[instance_id]],
                                constant float *peaks [[buffer(0)]],
                                constant BarsUniforms &u [[buffer(2)]]) {
    const float slot = 2.0 / float(u.barCount);
    const float x0 = -1.0 + slot * float(iid) + slot * (kBarGapFrac * 0.5);
    const float x1 = x0 + slot * (1.0 - kBarGapFrac);

    const float p = max(peaks[iid], 0.02);
    const float yC = kFloorY + 2.0 * kCeilFrac * p;
    const float capH = 0.012;       // ~6 px on a 1080p canvas
    const float y0 = yC - capH;
    const float y1 = yC + capH;

    const float2 verts[6] = {
        float2(x0, y0), float2(x1, y0), float2(x0, y1),
        float2(x1, y0), float2(x1, y1), float2(x0, y1)
    };

    BarsOut o;
    o.position = float4(verts[vid], 0.0, 1.0);
    o.palU = 1.0;       // always the brightest palette tap
    o.isPeak = 1.0;
    return o;
}

fragment float4 bars_fragment(BarsOut in [[stage_in]],
                              constant BarsUniforms &u [[buffer(2)]],
                              texture2d<float> palette [[texture(0)]]) {
    constexpr sampler s(filter::linear);

    // Vertical green→yellow→red gradient — sample palette by height.
    const float palU = clamp(0.15 + 0.75 * in.palU, 0.0, 1.0);
    float3 base = palette.sample(s, float2(palU, 0.5)).rgb;

    // Tip highlight: a thin lit band at the very top of the bar.
    const float tip = smoothstep(0.86, 1.00, in.palU);

    // Beat flash boosts brightness for the body (cap already pegs at palU=1).
    const float flashBoost = (1.0 - in.isPeak) * (1.0 + 0.30 * u.beatFlash);
    const float capBoost   = in.isPeak * 1.35;
    const float boost = max(flashBoost, capBoost);

    // Cap is whitened a touch so it reads as a separate element from the body.
    float3 col = mix(base, float3(1.0), tip * 0.30 + in.isPeak * 0.45);
    col *= boost;
    return float4(col, 1.0);
}
