#include <metal_stdlib>
using namespace metal;

// Canonical 2D-trick tunnel (Inigo Quilez's "Tunnel" technique).
// Project each fragment onto a cylinder by (u, v) = (angle/π, 1/r + scroll);
// shade a checkerboard pattern in (u, v) space with derivative AA via
// `fwidth(cell)`; fog the result with `exp(-depth * k)` so the centre fades
// into a vanishing point.

struct TunnelUniforms {
    float time;
    float aspect;
    float rms;
    float beat;          // [0, 1] beat envelope (decays in the scene)
    float beatAge;       // [0, 1] seconds-since-last-beat ramp
    float bass;
    float treble;
    float twist;         // depth-coupled twist freq (per `randomize`)
    float depth;         // tunnel radius / depth coefficient
    float nAng;          // angular checker cell count
    float nDep;          // depth checker cell count
    float direction;     // ±1 — flips scroll
    float trebleL;       // smoothed treble of the left channel (0 for mono)
    float trebleR;       // smoothed treble of the right channel (0 for mono)
    float stereoBias;    // [-1, 1] L/R bass balance (0 for mono / centered)
    float _pad0;
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

    // Aspect-correct fragment coord, then a slow audio-coupled camera roll.
    // stereoBias adds a gentle steady lean toward the heavier bass side so
    // the tunnel reads as panning with the music when the source is stereo.
    float2 p = in.uv;
    p.x *= u.aspect;
    float roll = u.time * 0.10
               + u.bass * 0.50 * sin(u.time * 0.30)
               + 0.05 * sin(u.time * 0.70)
               + u.stereoBias * 0.08;
    float cR = cos(roll), sR = sin(roll);
    p = float2(cR * p.x - sR * p.y, sR * p.x + cR * p.y);

    // Polar + the depth trick: r → screen radius, 1/r is the projection of
    // depth along a cylinder. `max(r, eps)` guards the singularity at centre.
    float r = length(p);
    float a = atan2(p.y, p.x);
    float depthZ = u.depth / max(r, 1e-3);
    float scroll = u.time * u.direction * (0.35 + u.rms * 2.5);

    // Per-side treble — cos(a) splits screen-left (≈ -1) from screen-right (≈ +1)
    // so the hi-freq ripple modulates asymmetrically on a stereo source. With a
    // mono source both halves of the mix are equal and this is a no-op.
    float sideMask = 0.5 + 0.5 * cos(a);                              // 0 = left, 1 = right
    float trebSide = mix(u.trebleL, u.trebleR, sideMask);
    float trebMix  = max(u.treble, trebSide);                         // never below the mono treble

    // (u, v) cylinder coordinates with bass-driven depth-coupled twist.
    float angU = a / 3.14159265;
    float twistAmt = 0.40 + 1.20 * u.bass;
    float depthV = depthZ + scroll
                 + trebMix * 0.04 * sin(a * 12.0 + u.time * 8.0);     // hi-freq ripple
    // Spiral + a steady angular drift toward the heavier bass side.
    angU += twistAmt * sin(depthV * 0.7) + u.stereoBias * 0.12;

    // Checkerboard in (u, v) — derivative-based AA via `fwidth(cell)`.
    float2 cell = float2(angU * u.nAng * 0.5, depthV * u.nDep);
    float2 g  = fract(cell) - 0.5;
    float2 fw = max(fwidth(cell), 1e-4);
    float2 e  = smoothstep(0.5 - fw, 0.5 + fw, abs(g));
    float chk = 1.0 - (e.x * (1.0 - e.y) + e.y * (1.0 - e.x));   // 0..1 AA checker

    // Palette advances with depth so colour visibly flies past.
    float palU = fract(depthV * 0.25 + u.rms * 0.30 + u.treble * 0.15);
    float3 colorBand = palette.sample(s, float2(palU, 0.5)).rgb;
    float shade = mix(0.30, 1.00, chk);
    float3 col = colorBand * shade;

    // Exponential depth fog.
    float fog = exp(-depthZ * 0.15);
    col *= fog;
    // Vanishing-point glow so the centre never reads as pure black.
    col += float3(0.04, 0.05, 0.08) * smoothstep(0.30, 0.00, r);

    // Beat shockwave — a decaying ring outward from the vanishing point.
    float beatBand = exp(-3.0 * fabs(r - 0.5 * (1.0 - u.beatAge)));
    col += u.beat * beatBand * float3(1.0, 0.7, 0.9) * 0.7;

    // Soft vignette.
    float vign = smoothstep(1.65, 0.40, length(in.uv));
    col *= vign;

    return float4(col, 1.0);
}
