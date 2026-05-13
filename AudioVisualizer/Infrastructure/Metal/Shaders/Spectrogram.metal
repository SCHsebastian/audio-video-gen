#include <metal_stdlib>
using namespace metal;

// Canonical spectrogram waterfall. Time scrolls horizontally (newest at the
// right edge), frequency runs vertically on a log axis (bass at the bottom,
// treble at the top). The CPU bakes a log-Hz + dB column per frame, the
// shader does the visual scroll via `fract(uv.x + writeColNorm)`.

struct SpecUniforms {
    float aspect;
    int   W;                // texture width (== history columns)
    int   H;                // texture height (== log-frequency rows)
    float writeColNorm;     // (col + 1) / W — where the *next* slot lives
    int   showPitchGrid;    // 0/1 — overlay faint A2..A6 lines
    float _pad0;
    float _pad1;
    float _pad2;
};

struct SVOut {
    float4 position [[position]];
    float2 ndc;
};

vertex SVOut spec_vertex(uint vid [[vertex_id]]) {
    float2 v[6] = { float2(-1,-1), float2(1,-1), float2(-1,1),
                    float2(1,-1),  float2(1,1),  float2(-1,1) };
    SVOut o;
    o.position = float4(v[vid], 0, 1);
    o.ndc = v[vid];
    return o;
}

fragment float4 spec_fragment(SVOut in [[stage_in]],
                              constant SpecUniforms &u [[buffer(1)]],
                              texture2d<float> palette [[texture(0)]],
                              texture2d<float> history [[texture(1)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);

    float2 uv = in.ndc * 0.5 + 0.5;            // [0, 1]^2

    // Time scroll: `uv.x = 0` shows the OLDEST column, `uv.x = 1` the newest.
    // The newest column lives at `writeColNorm - 1/W`, so the rotation is:
    //   u_tex = fract(uv.x + writeColNorm)
    float u_tex = fract(uv.x + u.writeColNorm);
    // The texture is already log-frequency-spaced row-wise, so a linear sample
    // on Y is the correct display mapping.
    float v_tex = uv.y;

    float mag = history.sample(s, float2(u_tex, v_tex)).r;     // already dB-normalized
    float3 col = palette.sample(s, float2(saturate(mag), 0.5)).rgb;

    // Optional pitch-class lines (A2..A6). f = 110, 220, 440, 880, 1760 Hz.
    if (u.showPitchGrid != 0) {
        const float F_MIN = 20.0;
        const float F_MAX = 24000.0;
        const float invLog = 1.0 / log2(F_MAX / F_MIN);    // == 1 / 10.23
        float f_row = F_MIN * pow(F_MAX / F_MIN, v_tex);
        // Distance in y to the nearest A-octave
        float yA2 = log2(110.0  / F_MIN) * invLog;
        float yA3 = log2(220.0  / F_MIN) * invLog;
        float yA4 = log2(440.0  / F_MIN) * invLog;
        float yA5 = log2(880.0  / F_MIN) * invLog;
        float yA6 = log2(1760.0 / F_MIN) * invLog;
        float dy = min(min(min(fabs(v_tex - yA2), fabs(v_tex - yA3)),
                            min(fabs(v_tex - yA4), fabs(v_tex - yA5))),
                       fabs(v_tex - yA6));
        float fw = fwidth(v_tex);
        float line = 1.0 - smoothstep(0.0, fw * 2.0, dy);
        col += float3(0.06) * line;
        (void)f_row;
    }

    return float4(col, 1.0);
}
