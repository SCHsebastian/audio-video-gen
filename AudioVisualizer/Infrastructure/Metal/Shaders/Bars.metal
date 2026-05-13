#include <metal_stdlib>
using namespace metal;

// Bars — classic spectrum analyzer with two design-only enhancements over
// the original layout:
//   * Each bar's quad is *widened* past its visible body, and the fragment
//     shader paints a saturated core surrounded by a Gaussian halo. Adjacent
//     bars' halos overlap so clustered peaks read as a continuous neon
//     ribbon instead of isolated sticks.
//   * In mono mode a second body pass renders the bars mirrored under the
//     floor line at a dim `reflectFactor` for a glossy-stage feel.
//
// Colours stay tied to the user palette exactly as before: height drives the
// body gradient, brightest tap colours the peak cap, no per-bar hue shift.

struct BarsUniforms {
    float aspect;
    float time;
    int   barCount;
    float beatFlash;
    float yOrigin;        // NDC y where bars are anchored
    float yDir;           // +1 grows up, -1 grows down
    float yScale;         // NDC distance for a unit-height bar
    float reflectFactor;  // 1.0 normal pass, < 1 dims/fades the reflection
};

struct BarsOut {
    float4 position [[position]];
    float  palU;          // 0 at base, 1 at tip — vertical palette gradient
    float  xNorm;         // -1 at left edge of widened quad, +1 at right
    float  isPeak;
};

constant float kBarGapFrac = 0.15;

vertex BarsOut bars_vertex(uint vid [[vertex_id]],
                           uint iid [[instance_id]],
                           constant float *heights [[buffer(0)]],
                           constant BarsUniforms &u [[buffer(2)]]) {
    const float slot = 2.0 / float(u.barCount);
    const float xCenter = -1.0 + slot * (float(iid) + 0.5);
    // Widen the quad past the visible body so the Gaussian halo can bleed
    // outward and overlap with neighbours.
    const float glowHalfW = slot * 0.95;

    const float h = max(heights[iid], 0.004);
    const float baseY = u.yOrigin;
    const float topY  = u.yOrigin + u.yDir * u.yScale * h;

    const float2 verts[6] = {
        float2(xCenter - glowHalfW, baseY), float2(xCenter + glowHalfW, baseY), float2(xCenter - glowHalfW, topY),
        float2(xCenter + glowHalfW, baseY), float2(xCenter + glowHalfW, topY),  float2(xCenter - glowHalfW, topY)
    };
    const float yLocal[6] = { 0.0, 0.0, 1.0,  0.0, 1.0, 1.0 };
    const float xLocal[6] = { -1.0, 1.0, -1.0,  1.0, 1.0, -1.0 };

    BarsOut o;
    o.position = float4(verts[vid], 0.0, 1.0);
    o.palU   = yLocal[vid];
    o.xNorm  = xLocal[vid];
    o.isPeak = 0.0;
    return o;
}

vertex BarsOut bars_peak_vertex(uint vid [[vertex_id]],
                                uint iid [[instance_id]],
                                constant float *peaks [[buffer(0)]],
                                constant BarsUniforms &u [[buffer(2)]]) {
    const float slot = 2.0 / float(u.barCount);
    const float xCenter = -1.0 + slot * (float(iid) + 0.5);
    const float coreHalfW = slot * (1.0 - kBarGapFrac) * 0.5;

    const float p = max(peaks[iid], 0.02);
    const float yC = u.yOrigin + u.yDir * u.yScale * p;
    const float capH = 0.012;
    const float y0 = yC - capH;
    const float y1 = yC + capH;

    const float2 verts[6] = {
        float2(xCenter - coreHalfW, y0), float2(xCenter + coreHalfW, y0), float2(xCenter - coreHalfW, y1),
        float2(xCenter + coreHalfW, y0), float2(xCenter + coreHalfW, y1), float2(xCenter - coreHalfW, y1)
    };

    BarsOut o;
    o.position = float4(verts[vid], 0.0, 1.0);
    o.palU   = 1.0;
    o.xNorm  = 0.0;
    o.isPeak = 1.0;
    return o;
}

fragment float4 bars_fragment(BarsOut in [[stage_in]],
                              constant BarsUniforms &u [[buffer(2)]],
                              texture2d<float> palette [[texture(0)]]) {
    constexpr sampler s(filter::linear);

    // Original vertical palette gradient — sampled by height (palU).
    const float palU = clamp(0.15 + 0.75 * in.palU, 0.0, 1.0);
    float3 base = palette.sample(s, float2(palU, 0.5)).rgb;

    if (in.isPeak >= 0.5) {
        // Peak cap — palette tip colour pulled toward white, brightened.
        float3 capCol = mix(base, float3(1.0), 0.45);
        capCol *= 1.35 * u.reflectFactor;
        return float4(capCol, 1.0 * u.reflectFactor);
    }

    // Tip highlight band at the very top of the body.
    const float tip = smoothstep(0.86, 1.00, in.palU);
    base = mix(base, float3(1.0), tip * 0.30);
    base *= (1.0 + 0.30 * u.beatFlash);

    // Horizontal core/glow split. `core` masks the saturated body; `glow` is
    // a Gaussian halo that extends past the core into the widened quad.
    float dx = fabs(in.xNorm);
    float coreEdge = (1.0 - kBarGapFrac) * 0.5 / 0.95;
    float core = smoothstep(coreEdge + 0.03, coreEdge - 0.03, dx);
    float glow = exp(-pow(dx * 1.6, 2.0));

    float3 glowCol = base * 0.85;
    float3 outCol  = mix(glowCol * glow * 0.65, base, core);
    float outAlpha = max(core, glow * 0.55);

    outCol   *= u.reflectFactor;
    outAlpha *= u.reflectFactor;
    return float4(outCol, outAlpha);
}
