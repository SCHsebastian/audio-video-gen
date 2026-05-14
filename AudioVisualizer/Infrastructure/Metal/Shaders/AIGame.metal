#include <metal_stdlib>
using namespace metal;

// ----------------------------------------------------------------------------
// AI Game scene — terrain strip + obstacle quads + agent quads.
// All three pipelines share the same camera-shake offset uniform; obstacles
// and agents are instanced. Palette texture is sampled for color so the scene
// inherits the user's currently-active palette like every other scene.
// ----------------------------------------------------------------------------

struct AIGameSceneUniforms {
    float aspect;
    float time;
    float cameraX;
    float cameraOffsetX;
    float cameraOffsetY;
    float rms;
    float beat;
};

struct VOut {
    float4 position [[position]];
    float2 local;        // -1..1 within the primitive
    float  paletteU;     // 0..1
    float  flags;        // 0 = neutral, 1 = danger, 2 = pit
};

// ----- Terrain strip ---------------------------------------------------------
// Vertex stream: pairs (x_world, y_top) and (x_world, y_bottom=-1). We build
// the strip CPU-side as floats and pass per-vertex.

struct TerrainVertex {
    float2 worldPos;     // world coords (x, y)
};

vertex VOut aigame_terrain_vertex(uint vid [[vertex_id]],
                                  constant TerrainVertex* verts [[buffer(0)]],
                                  constant AIGameSceneUniforms& u [[buffer(1)]]) {
    float2 wp = verts[vid].worldPos;
    float2 ndc = float2((wp.x - u.cameraX), wp.y) + float2(u.cameraOffsetX, u.cameraOffsetY);
    ndc.x /= u.aspect;
    VOut o;
    o.position = float4(ndc, 0, 1);
    o.local    = float2(0, wp.y);
    o.paletteU = 0.92;
    o.flags    = 0;
    return o;
}

fragment float4 aigame_terrain_fragment(VOut in [[stage_in]],
                                        constant AIGameSceneUniforms& u [[buffer(1)]],
                                        texture2d<float> palette [[texture(0)]]) {
    constexpr sampler s(filter::linear);
    float4 c = palette.sample(s, float2(in.paletteU, 0.5));
    c.rgb *= 0.55 + 0.25 * u.rms;
    return c;
}

// ----- Obstacle instanced quads ---------------------------------------------

struct ObstacleInstance {
    float2 worldPos;     // bottom-left in world coords
    float2 size;         // width, height in world units
    float  flags;        // 0 spike, 1 ceiling, 2 pit
};

vertex VOut aigame_obstacle_vertex(uint vid [[vertex_id]],
                                   uint iid [[instance_id]],
                                   constant ObstacleInstance* insts [[buffer(0)]],
                                   constant AIGameSceneUniforms& u [[buffer(1)]]) {
    float2 quad[6] = { float2(0,0), float2(1,0), float2(0,1),
                       float2(1,0), float2(1,1), float2(0,1) };
    float2 q = quad[vid];
    ObstacleInstance ins = insts[iid];
    // Pit: draw downward (height extends below ground).
    float2 size = ins.flags == 2.0 ? float2(ins.size.x, -ins.size.y) : ins.size;
    float2 wp = ins.worldPos + float2(q.x * size.x, q.y * size.y);
    float2 ndc = float2((wp.x - u.cameraX), wp.y) + float2(u.cameraOffsetX, u.cameraOffsetY);
    ndc.x /= u.aspect;
    VOut o;
    o.position = float4(ndc, 0, 1);
    o.local    = q * 2 - 1;
    o.paletteU = 0.55;
    o.flags    = ins.flags;
    return o;
}

fragment float4 aigame_obstacle_fragment(VOut in [[stage_in]],
                                         texture2d<float> palette [[texture(0)]]) {
    constexpr sampler s(filter::linear);
    float4 c = palette.sample(s, float2(in.paletteU, 0.5));
    if (in.flags == 0.0)      c.rgb = mix(c.rgb, float3(1.0, 0.25, 0.20), 0.55);
    else if (in.flags == 1.0) c.rgb = mix(c.rgb, float3(1.0, 0.55, 0.20), 0.55);
    else                       c.rgb = float3(0.04, 0.02, 0.06);
    // Soft rounded edge.
    float r = length(in.local);
    float aa = 1.0 - smoothstep(0.92, 1.0, r);
    return float4(c.rgb, aa);
}

// ----- Agent instanced quads -------------------------------------------------

struct AgentInstance {
    float2 worldPos;     // center in world coords
    float  size;         // radius
    float  colorSeed;    // 0..1, palette u
    float  alive;        // 1 alive / 0 dead
};

vertex VOut aigame_agent_vertex(uint vid [[vertex_id]],
                                uint iid [[instance_id]],
                                constant AgentInstance* insts [[buffer(0)]],
                                constant AIGameSceneUniforms& u [[buffer(1)]]) {
    float2 quad[6] = { float2(-1,-1), float2( 1,-1), float2(-1, 1),
                       float2( 1,-1), float2( 1, 1), float2(-1, 1) };
    AgentInstance ins = insts[iid];
    float2 q = quad[vid];
    float2 wp = ins.worldPos + q * ins.size;
    float2 ndc = float2((wp.x - u.cameraX), wp.y) + float2(u.cameraOffsetX, u.cameraOffsetY);
    ndc.x /= u.aspect;
    VOut o;
    o.position = float4(ndc, 0, 1);
    o.local    = q;
    o.paletteU = ins.colorSeed;
    o.flags    = ins.alive;
    return o;
}

fragment float4 aigame_agent_fragment(VOut in [[stage_in]],
                                      texture2d<float> palette [[texture(0)]]) {
    constexpr sampler s(filter::linear);
    float r = length(in.local);
    float body = 1.0 - smoothstep(0.85, 1.0, r);
    if (body <= 0) discard_fragment();
    float4 c = palette.sample(s, float2(in.paletteU, 0.5));
    // Two eyes: small dark dots at (±0.35, 0.25).
    float2 le = in.local - float2(-0.35, 0.25);
    float2 re = in.local - float2( 0.35, 0.25);
    float eye = max(1.0 - smoothstep(0.05, 0.12, length(le)),
                    1.0 - smoothstep(0.05, 0.12, length(re)));
    c.rgb = mix(c.rgb, float3(0.05, 0.05, 0.10), eye);
    float a = body * (in.flags > 0.5 ? 0.65 : 0.18); // dim dead agents
    return float4(c.rgb * a, a);
}
