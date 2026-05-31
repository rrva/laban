#include <metal_stdlib>
using namespace metal;

// Per-instance solid quad (rect + color in NDC after vertex transform).
struct SolidInstance {
    float2 origin;   // bottom-left in pixels (CG coords, y-up)
    float2 size;     // pixels
    float4 color;    // 0..1 rgba (premultiplied applied in shader)
};

// Per-instance textured (glyph) quad. uvOrigin/uvSize address the atlas.
struct GlyphInstance {
    float2 origin;
    float2 size;
    float2 uvOrigin;
    float2 uvSize;
    float4 color;
};

// Per-cell glyph record used by the GPU-driven renderer. Geometry is already
// resolved on the CPU with the same arithmetic as the classic GlyphInstance
// path; instance_id selects a record but never derives row/column position.
struct CellGlyph {
    float2 originPx;
    float2 sizePx;
    float2 uvOrigin;
    float2 uvSize;
    uint flags;
    uint _pad0;
    uint _pad1;
    uint _pad2;
    float4 fg;
};

struct Uniforms {
    float2 surfaceSizePixels;  // pixel dims of the render target
    float  scale;              // backing scale (for line thickness etc.)
};

struct VOut {
    float4 position [[position]];
    float4 color;
    float2 uv;
};

// Quad vertex order: 0 BL, 1 BR, 2 TL, 3 TR. Indexed 0,1,2, 2,1,3.
constant float2 kQuadVertices[6] = {
    float2(0, 0), float2(1, 0), float2(0, 1),
    float2(0, 1), float2(1, 0), float2(1, 1),
};

// CG-pixel space (y-up, 0..size) -> NDC (-1..+1). y is already up so map directly.
inline float2 toNDC(float2 px, float2 surface) {
    return float2(
        (px.x / surface.x) * 2.0 - 1.0,
        (px.y / surface.y) * 2.0 - 1.0
    );
}

// MARK: - Solid pipeline

vertex VOut solid_vertex(
    uint vertexId   [[vertex_id]],
    uint instanceId [[instance_id]],
    constant SolidInstance *instances [[buffer(0)]],
    constant Uniforms      &u         [[buffer(1)]]
) {
    SolidInstance inst = instances[instanceId];
    float2 unit = kQuadVertices[vertexId];
    float2 px = inst.origin + unit * inst.size;

    VOut o;
    o.position = float4(toNDC(px, u.surfaceSizePixels), 0.0, 1.0);
    o.color = inst.color;
    o.uv = float2(0, 0);
    return o;
}

fragment float4 solid_fragment(VOut in [[stage_in]]) {
    // Premultiplied output: rgb already multiplied by alpha at composite time
    // is done by the blend state config; here we hand over straight rgba and
    // rely on the source-over blend the render pipeline declares.
    return float4(in.color.rgb * in.color.a, in.color.a);
}

// MARK: - Glyph pipeline (samples r8 alpha mask, tints with per-instance color)

vertex VOut glyph_vertex(
    uint vertexId   [[vertex_id]],
    uint instanceId [[instance_id]],
    constant GlyphInstance *instances [[buffer(0)]],
    constant Uniforms      &u         [[buffer(1)]]
) {
    GlyphInstance inst = instances[instanceId];
    float2 unit = kQuadVertices[vertexId];
    float2 px = inst.origin + unit * inst.size;

    VOut o;
    o.position = float4(toNDC(px, u.surfaceSizePixels), 0.0, 1.0);
    o.color = inst.color;
    // Atlas is stored upright; flip v because the atlas was filled
    // top-down by CGContext (origin top-left in image coords).
    o.uv = float2(inst.uvOrigin.x + unit.x * inst.uvSize.x,
                  inst.uvOrigin.y + (1.0 - unit.y) * inst.uvSize.y);
    return o;
}

vertex VOut cell_glyph_vertex(
    uint vertexId   [[vertex_id]],
    uint instanceId [[instance_id]],
    constant CellGlyph *cells [[buffer(0)]],
    constant Uniforms  &u     [[buffer(1)]]
) {
    CellGlyph cell = cells[instanceId];
    float2 unit = kQuadVertices[vertexId];
    float2 px = cell.originPx + unit * cell.sizePx;

    VOut o;
    o.position = float4(toNDC(px, u.surfaceSizePixels), 0.0, 1.0);
    o.color = cell.fg;
    o.uv = float2(cell.uvOrigin.x + unit.x * cell.uvSize.x,
                  cell.uvOrigin.y + (1.0 - unit.y) * cell.uvSize.y);
    return o;
}

fragment float4 glyph_fragment(
    VOut in [[stage_in]],
    texture2d<float> atlas [[texture(0)]],
    sampler atlasSampler [[sampler(0)]]
) {
    float coverage = atlas.sample(atlasSampler, in.uv).r;
    // Premultiplied source-over: output = (color.rgb * color.a, color.a) * coverage.
    float a = in.color.a * coverage;
    return float4(in.color.rgb * a, a);
}
