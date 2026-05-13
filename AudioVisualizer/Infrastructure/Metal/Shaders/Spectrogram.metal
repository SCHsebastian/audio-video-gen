#include <metal_stdlib>
using namespace metal;

struct SpecUniforms {
    float aspect;
    int   bandCount;       // columns in the history texture (X axis)
    int   historyRows;     // total rows allocated
    int   writeIndex;      // next row the CPU will write to (oldest visible)
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

// Spectrogram waterfall. The CPU keeps a ring buffer of spectrum frames in an
// `r32float` texture (rows = history depth, columns = bands). We map screen
// UVs through the ring's `writeIndex` so newest history scrolls up from the
// bottom edge.
fragment float4 spec_fragment(SVOut in [[stage_in]],
                              constant SpecUniforms &u [[buffer(1)]],
                              texture2d<float> palette [[texture(0)]],
                              texture2d<float> history [[texture(1)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    // Map ndc to [0, 1].
    float2 uv = in.ndc * 0.5 + 0.5;
    // x → frequency band (logarithmic feel via sqrt for low-end emphasis)
    float fx = sqrt(uv.x);
    int   bx = int(clamp(fx * float(u.bandCount - 1), 0.0, float(u.bandCount - 1)));
    // y → time. Bottom (y=0) is "now", top (y=1) is oldest visible.
    int rows = u.historyRows;
    int age  = int((1.0 - uv.y) * float(rows - 1));
    int row  = (u.writeIndex - 1 - age + rows * 2) % rows;
    float2 texUV = float2((float(bx) + 0.5) / float(u.bandCount),
                          (float(row) + 0.5) / float(rows));
    float mag = history.sample(s, texUV).r;
    // Compress dynamic range a bit so quiet bands still show.
    float v = pow(clamp(mag, 0.0, 1.0), 0.55);
    float3 c = palette.sample(s, float2(v, 0.5)).rgb;
    // Subtle horizontal scan line for that "diagnostic instrument" feel.
    float scan = 0.04 * (1.0 - 0.5 * fract(uv.y * float(rows) * 0.5));
    return float4(c * (1.0 - 0.05) + float3(scan), 1.0);
}
