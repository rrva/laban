#include <metal_stdlib>
using namespace metal;

struct VectorSolidInstance {
    float2 origin;
    float2 size;
    float4 color;
};

struct VectorGlyphInstance {
    float2 origin;
    float2 size;
    float2 uvOrigin;
    float2 uvSize;
    float4 color;
    float coverageExponent;
};

struct VectorRenderUniforms {
    float2 surfaceSizePixels;
    float scale;
    // Continuous-zoom gesture factor applied in the projection so EVERY
    // presented frame is consistently scaled (no CALayer transform racing the
    // self-presenting render loop). 1.0 = no gesture zoom. The scale is about
    // `gestureZoomAnchorPixels` (device px, y-up from bottom-left).
    float gestureZoom;
    float2 gestureZoomAnchorPixels;
    float _pad;
};

struct VectorVertexOut {
    float4 position [[position]];
    float4 color;
    float2 uv;
    float coverageExponent;
};

struct VectorGlyphCurve {
    float2 p0;
    float2 p1;
    float2 p2;
};

struct VectorGlyphRasterParams {
    uint curveCount;
    uint width;
    uint height;
    uint _pad0;
    float2 origin;
    float2 boundsMin;
    float2 boundsMax;
    float rasterScale;
    float _pad1;
};

struct VectorGlyphAccumParams {
    uint curveCount;
    uint width;
    uint height;
    uint sampleStart;
    uint sampleCount;
    uint seed;
    uint2 targetOrigin;
    float2 origin;
    float2 boundsMin;
    float2 boundsMax;
    float rasterScale;
    float _pad0;
    float4 subpixelRBounds;
    float4 subpixelGBounds;
    float4 subpixelBBounds;
    // Sub-pixel phase (device-pixel fraction) baked into the sample grid so a
    // mask cached for a fractional on-screen position samples the outline at the
    // matching phase (OSOR per-phase glyph caching). Zero for static text.
    float2 subpixelOffset;
};

constant float2 kVectorQuadVertices[6] = {
    float2(0.0, 0.0), float2(1.0, 0.0), float2(0.0, 1.0),
    float2(0.0, 1.0), float2(1.0, 0.0), float2(1.0, 1.0),
};

inline float2 vector_to_ndc(float2 px, float2 surface) {
    return float2(
        (px.x / surface.x) * 2.0 - 1.0,
        (px.y / surface.y) * 2.0 - 1.0
    );
}

// Apply the continuous-zoom gesture factor in device-pixel space, about the
// anchor, before NDC projection. Identity when zoom == 1.
inline float2 vector_apply_gesture_zoom(float2 px, constant VectorRenderUniforms &u) {
    return (px - u.gestureZoomAnchorPixels) * u.gestureZoom + u.gestureZoomAnchorPixels;
}

vertex VectorVertexOut vectorSolidVertex(
    uint vertexId [[vertex_id]],
    uint instanceId [[instance_id]],
    constant VectorSolidInstance *instances [[buffer(0)]],
    constant VectorRenderUniforms &uniforms [[buffer(1)]]
) {
    VectorSolidInstance instance = instances[instanceId];
    float2 unit = kVectorQuadVertices[vertexId];
    float2 px = instance.origin + unit * instance.size;
    px = vector_apply_gesture_zoom(px, uniforms);

    VectorVertexOut out;
    out.position = float4(vector_to_ndc(px, uniforms.surfaceSizePixels), 0.0, 1.0);
    out.color = instance.color;
    out.uv = float2(0.0, 0.0);
    out.coverageExponent = 1.0;
    return out;
}

fragment float4 vectorSolidFragment(VectorVertexOut in [[stage_in]]) {
    return float4(in.color.rgb * in.color.a, in.color.a);
}

vertex VectorVertexOut vectorGlyphVertex(
    uint vertexId [[vertex_id]],
    uint instanceId [[instance_id]],
    constant VectorGlyphInstance *instances [[buffer(0)]],
    constant VectorRenderUniforms &uniforms [[buffer(1)]]
) {
    VectorGlyphInstance instance = instances[instanceId];
    float2 unit = kVectorQuadVertices[vertexId];
    float2 px = instance.origin + unit * instance.size;
    px = vector_apply_gesture_zoom(px, uniforms);

    VectorVertexOut out;
    out.position = float4(vector_to_ndc(px, uniforms.surfaceSizePixels), 0.0, 1.0);
    out.color = instance.color;
    out.uv = float2(
        instance.uvOrigin.x + unit.x * instance.uvSize.x,
        instance.uvOrigin.y + (1.0 - unit.y) * instance.uvSize.y
    );
    out.coverageExponent = instance.coverageExponent;
    return out;
}

fragment float4 vectorGlyphCoverageFragment(
    VectorVertexOut in [[stage_in]],
    texture2d<float> atlas [[texture(0)]],
    sampler atlasSampler [[sampler(0)]]
) {
    float3 coverage = pow(atlas.sample(atlasSampler, in.uv).rgb, float3(in.coverageExponent));
    return float4(coverage * in.color.a, 0.0);
}

fragment float4 vectorGlyphColorFragment(
    VectorVertexOut in [[stage_in]],
    texture2d<float> atlas [[texture(0)]],
    sampler atlasSampler [[sampler(0)]]
) {
    float3 coverage = pow(atlas.sample(atlasSampler, in.uv).rgb, float3(in.coverageExponent));
    return float4(in.color.rgb * coverage * in.color.a, 0.0);
}

fragment float4 vectorRasterGlyphFragment(
    VectorVertexOut in [[stage_in]],
    texture2d<float> atlas [[texture(0)]],
    sampler atlasSampler [[sampler(0)]]
) {
    float coverage = atlas.sample(atlasSampler, in.uv).r;
    float alpha = in.color.a * coverage;
    return float4(in.color.rgb * alpha, alpha);
}

inline float srgb_to_linear(float c) {
    return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4);
}

fragment float4 vectorColorGlyphFragment(
    VectorVertexOut in [[stage_in]],
    texture2d<float> atlas [[texture(0)]],
    sampler atlasSampler [[sampler(0)]]
) {
    float4 sample = atlas.sample(atlasSampler, in.uv);
    // Emoji atlas stores straight sRGB color; linearize before premultiplying
    // so it composites correctly into the sRGB (linear-light) target.
    float3 lin = float3(
        srgb_to_linear(sample.r),
        srgb_to_linear(sample.g),
        srgb_to_linear(sample.b));
    return float4(lin * sample.a, sample.a);
}

inline float curve_x_at(VectorGlyphCurve curve, float t) {
    float u = 1.0 - t;
    return u * u * curve.p0.x + 2.0 * u * t * curve.p1.x + t * t * curve.p2.x;
}

inline bool valid_root(float t, VectorGlyphCurve curve) {
    constexpr float eps = 1.0e-6;
    if (t < -eps || t >= 1.0 - eps) {
        return false;
    }
    float clamped = clamp(t, 0.0, 1.0);
    return curve_x_at(curve, clamped) >= -eps;
}

inline int winding_contribution(VectorGlyphCurve curve) {
    constexpr float eps = 1.0e-6;
    float y0 = curve.p0.y;
    float y1 = curve.p1.y;
    float y2 = curve.p2.y;
    float a = y0 - 2.0 * y1 + y2;
    float b = y0 - y1;
    float c = y0;

    if (fabs(a) <= eps) {
        if (fabs(b) <= eps) {
            return 0;
        }
        float t = c / (2.0 * b);
        if (!valid_root(t, curve)) {
            return 0;
        }
        // derivative = -2*b; b>0 => downward crossing => +1.
        return b > 0.0 ? 1 : -1;
    }

    // FMA computes b*b - a*c with a single rounding, avoiding the spurious
    // sign flip that plain (b*b) - (a*c) can produce for near-tangent crossings.
    float discriminant = fma(b, b, -a * c);
    if (discriminant <= 0.0) {
        return 0;
    }

    float root = sqrt(discriminant);
    // Numerically stable roots of a*t^2 - 2*b*t + c = 0. Straight strokes are
    // encoded as collinear (degenerate) quadratics whose `a` rounds to a tiny
    // non-zero value in 32-bit float. The naive (b - root)/a then suffers
    // catastrophic cancellation (b ~= root), producing garbage crossings that
    // garble line glyphs (e.g. `/`, `N`, `X`) at the sizes where the sample
    // grid lands in the cancellation zone. Vieta's form keeps the small root
    // full-precision; the large root falls out of [0,1) and is rejected.
    float s = b + (b >= 0.0 ? root : -root);
    float t0;  // downward crossing (+1) = (b - root)/a
    float t1;  // upward crossing (-1) = (b + root)/a
    if (b >= 0.0) {
        t0 = c / s;
        t1 = s / a;
    } else {
        t0 = s / a;
        t1 = c / s;
    }
    int winding = 0;
    if (valid_root(t0, curve)) {
        winding += 1;
    }
    if (valid_root(t1, curve)) {
        winding -= 1;
    }
    return winding;
}

inline float vector_r2(uint index, uint seed, float alpha, uint shift) {
    uint mixed = seed ^ (seed >> shift);
    float seedOffset = float(mixed & 0xffffu) / 65536.0;
    return fract((float(index) + 0.5) * alpha + seedOffset);
}

inline float vector_point_coverage_at(
    constant VectorGlyphCurve *curves,
    uint curveCount,
    float2 sample,
    float2 boundsMin,
    float2 boundsMax
) {
    if (sample.x < boundsMin.x || sample.x > boundsMax.x ||
        sample.y < boundsMin.y || sample.y > boundsMax.y) {
        return 0.0;
    }

    int winding = 0;
    for (uint i = 0; i < curveCount; i++) {
        VectorGlyphCurve curve = curves[i];
        curve.p0 -= sample;
        curve.p1 -= sample;
        curve.p2 -= sample;
        winding += winding_contribution(curve);
    }
    return clamp(float(abs(winding)), 0.0, 1.0);
}

inline float2 vector_sample_in_bounds(float4 bounds, float2 unit) {
    return mix(bounds.xy, bounds.zw, unit);
}

kernel void vectorGlyphRasterizeScratch(
    constant VectorGlyphCurve *curves [[buffer(0)]],
    constant VectorGlyphRasterParams &params [[buffer(1)]],
    constant uint2 &targetOrigin [[buffer(2)]],
    texture2d<float, access::write> output [[texture(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= params.width || gid.y >= params.height) {
        return;
    }

    float2 sample = float2(
        params.origin.x + (float(gid.x) + 0.5) / params.rasterScale,
        params.origin.y + (float(params.height - 1 - gid.y) + 0.5) / params.rasterScale
    );
    if (sample.x < params.boundsMin.x || sample.x > params.boundsMax.x ||
        sample.y < params.boundsMin.y || sample.y > params.boundsMax.y) {
        output.write(float4(0.0, 0.0, 0.0, 1.0), targetOrigin + gid);
        return;
    }

    int winding = 0;
    for (uint i = 0; i < params.curveCount; i++) {
        VectorGlyphCurve curve = curves[i];
        curve.p0 -= sample;
        curve.p1 -= sample;
        curve.p2 -= sample;
        winding += winding_contribution(curve);
    }

    float coverage = clamp(float(abs(winding)), 0.0, 1.0);
    output.write(float4(coverage, 0.0, 0.0, 1.0), targetOrigin + gid);
}

kernel void vectorGlyphAccumulateAtlas(
    constant VectorGlyphCurve *curves [[buffer(0)]],
    constant VectorGlyphAccumParams &params [[buffer(1)]],
    texture2d<uint, access::read_write> accum [[texture(0)]],
    texture2d<float, access::write> resolved [[texture(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= params.width || gid.y >= params.height) {
        return;
    }

    uint2 atlasPosition = params.targetOrigin + gid;
    uint4 state = params.sampleStart == 0 ? uint4(0) : accum.read(atlasPosition);
    uint3 sum = uint3(0);
    // Bias the sample grid by the cached sub-pixel phase so a mask baked for a
    // fractional on-screen position samples the outline at that phase. Zero for
    // static (integer-cell) text, which keeps a single phase-0 mask per glyph.
    float2 pixelBase = float2(
        float(gid.x),
        float(params.height - 1 - gid.y)
    ) + params.subpixelOffset;
    for (uint sampleIndex = 0; sampleIndex < params.sampleCount; sampleIndex++) {
        uint absoluteSample = params.sampleStart + sampleIndex;
        float2 jitter = float2(
            vector_r2(absoluteSample, params.seed, 0.754877666, 7),
            vector_r2(absoluteSample, params.seed, 0.569840296, 13)
        );
        float2 sampleR = params.origin
            + (pixelBase + vector_sample_in_bounds(params.subpixelRBounds, jitter))
                / params.rasterScale;
        float2 sampleG = params.origin
            + (pixelBase + vector_sample_in_bounds(params.subpixelGBounds, jitter))
                / params.rasterScale;
        float2 sampleB = params.origin
            + (pixelBase + vector_sample_in_bounds(params.subpixelBBounds, jitter))
                / params.rasterScale;
        float coverageR = vector_point_coverage_at(
            curves,
            params.curveCount,
            sampleR,
            params.boundsMin,
            params.boundsMax
        );
        float coverageG = vector_point_coverage_at(
            curves,
            params.curveCount,
            sampleG,
            params.boundsMin,
            params.boundsMax
        );
        float coverageB = vector_point_coverage_at(
            curves,
            params.curveCount,
            sampleB,
            params.boundsMin,
            params.boundsMax
        );
        sum += uint3(
            uint(round(coverageR * 65535.0)),
            uint(round(coverageG * 65535.0)),
            uint(round(coverageB * 65535.0))
        );
    }

    state.xyz += sum;
    state.w += params.sampleCount;
    accum.write(state, atlasPosition);

    float3 alpha = state.w == 0
        ? float3(0.0)
        : float3(state.xyz) / (float(state.w) * 65535.0);
    alpha = clamp(alpha, 0.0, 1.0);
    // Snap single-sample quantization noise (1/512 ~= 0.002) to the extremes so
    // stems read fully solid and the background stays fully clear (OSOR's
    // extreme-coverage clamp).
    alpha = select(alpha, float3(0.0), alpha < 0.002);
    alpha = select(alpha, float3(1.0), alpha > 0.998);
    resolved.write(float4(alpha, 1.0), atlasPosition);
}

struct SlugSpikeGlyph {
    float2 boundsMin;
    float2 boundsMax;
    uint curveStart;
    uint curveCount;
    uint bandStart;
    uint bandCount;
};

struct SlugSpikeBand {
    uint indexStart;
    uint indexCount;
};

struct SlugSpikeInstance {
    float2 originPx;
    float2 sizePx;
    float2 localMin;
    float2 localMax;
    float4 color;
    uint glyphIndex;
    uint pad0;
    uint pad1;
    uint pad2;
};

struct SlugSpikeUniforms {
    float2 surfaceSizePixels;
};

struct SlugSpikeVertexOut {
    float4 position [[position]];
    float2 glyphPoint;
    float4 color;
    float glyphIndex;
};

vertex SlugSpikeVertexOut slugGlyphVertexSpike(
    uint vertexId [[vertex_id]],
    uint instanceId [[instance_id]],
    constant SlugSpikeInstance *instances [[buffer(0)]],
    constant SlugSpikeUniforms &uniforms [[buffer(1)]]
) {
    SlugSpikeInstance instance = instances[instanceId];
    float2 unit = kVectorQuadVertices[vertexId];
    float2 px = instance.originPx + unit * instance.sizePx;

    SlugSpikeVertexOut out;
    out.position = float4(vector_to_ndc(px, uniforms.surfaceSizePixels), 0.0, 1.0);
    out.glyphPoint = mix(instance.localMin, instance.localMax, unit);
    out.color = instance.color;
    out.glyphIndex = float(instance.glyphIndex);
    return out;
}

inline bool slugGlyphContainsPointSpike(SlugSpikeGlyph glyph, float2 point) {
    constexpr float eps = 1.0e-6;
    return point.x >= glyph.boundsMin.x - eps &&
        point.x <= glyph.boundsMax.x + eps &&
        point.y >= glyph.boundsMin.y - eps &&
        point.y <= glyph.boundsMax.y + eps;
}

inline float slugGlyphCoverageFromCurveSpike(VectorGlyphCurve curve, float2 sample) {
    curve.p0 -= sample;
    curve.p1 -= sample;
    curve.p2 -= sample;
    return float(winding_contribution(curve));
}

inline float slugGlyphNoBandCoverageSpike(
    constant VectorGlyphCurve *curves,
    SlugSpikeGlyph glyph,
    float2 sample
) {
    if (!slugGlyphContainsPointSpike(glyph, sample)) {
        return 0.0;
    }

    int winding = 0;
    for (uint i = 0; i < glyph.curveCount; i++) {
        winding += int(slugGlyphCoverageFromCurveSpike(curves[glyph.curveStart + i], sample));
    }
    return clamp(float(abs(winding)), 0.0, 1.0);
}

inline float slugGlyphBandCoverageSpike(
    constant VectorGlyphCurve *curves,
    constant SlugSpikeBand *bands,
    constant uint *bandIndices,
    SlugSpikeGlyph glyph,
    float2 sample
) {
    if (!slugGlyphContainsPointSpike(glyph, sample) || glyph.bandCount == 0) {
        return 0.0;
    }

    float height = max(glyph.boundsMax.y - glyph.boundsMin.y, 1.0e-6);
    float normalized = clamp((sample.y - glyph.boundsMin.y) / height, 0.0, 0.999999);
    uint bandIndex = min(glyph.bandCount - 1, uint(floor(normalized * float(glyph.bandCount))));
    SlugSpikeBand band = bands[glyph.bandStart + bandIndex];

    int winding = 0;
    for (uint i = 0; i < band.indexCount; i++) {
        uint curveIndex = bandIndices[band.indexStart + i];
        winding += int(slugGlyphCoverageFromCurveSpike(curves[curveIndex], sample));
    }
    return clamp(float(abs(winding)), 0.0, 1.0);
}

fragment float4 slugGlyphNoBandFragmentSpike(
    SlugSpikeVertexOut in [[stage_in]],
    constant VectorGlyphCurve *curves [[buffer(0)]],
    constant SlugSpikeGlyph *glyphs [[buffer(1)]]
) {
    uint glyphIndex = uint(in.glyphIndex + 0.5);
    float coverage = slugGlyphNoBandCoverageSpike(curves, glyphs[glyphIndex], in.glyphPoint);
    float alpha = coverage * in.color.a;
    return float4(in.color.rgb * alpha, alpha);
}

fragment float4 slugGlyphBandFragmentSpike(
    SlugSpikeVertexOut in [[stage_in]],
    constant VectorGlyphCurve *curves [[buffer(0)]],
    constant SlugSpikeGlyph *glyphs [[buffer(1)]],
    constant SlugSpikeBand *bands [[buffer(2)]],
    constant uint *bandIndices [[buffer(3)]]
) {
    uint glyphIndex = uint(in.glyphIndex + 0.5);
    float coverage = slugGlyphBandCoverageSpike(
        curves,
        bands,
        bandIndices,
        glyphs[glyphIndex],
        in.glyphPoint
    );
    float alpha = coverage * in.color.a;
    return float4(in.color.rgb * alpha, alpha);
}

struct SlugGlyph {
    float2 boundsMin;
    float2 boundsMax;
    uint curveStart;
    uint curveCount;
    uint horizontalBandStart;
    uint horizontalBandCount;
    uint verticalBandStart;
    uint verticalBandCount;
};

struct SlugGlyphBand {
    uint indexStart;
    uint indexCount;
};

struct SlugGlyphInstance {
    float2 originPx;
    float2 sizePx;
    float2 localMin;
    float2 localMax;
    float4 color;
    uint glyphIndex;
    uint pad0;
    uint pad1;
    uint pad2;
};

struct SlugGlyphUniforms {
    float2 surfaceSizePixels;
    float scale;
    float gestureZoom;
    float2 gestureZoomAnchor;
    float2 _pad0;
    float4 subpixelRBounds;
    float4 subpixelGBounds;
    float4 subpixelBBounds;
    uint subpixelMode;
    uint _pad1;
    uint _pad2;
    uint _pad3;
};

struct SlugGlyphVertexOut {
    float4 position [[position]];
    float2 glyphPoint;
    float4 color;
    float glyphIndex;
};

inline float2 slugGlyphApplyGestureZoom(float2 px, constant SlugGlyphUniforms &uniforms) {
    return (px - uniforms.gestureZoomAnchor) * uniforms.gestureZoom + uniforms.gestureZoomAnchor;
}

vertex SlugGlyphVertexOut slugGlyphVertex(
    uint vertexId [[vertex_id]],
    uint instanceId [[instance_id]],
    constant SlugGlyphInstance *instances [[buffer(0)]],
    constant SlugGlyphUniforms &uniforms [[buffer(1)]]
) {
    SlugGlyphInstance instance = instances[instanceId];
    float2 unit = kVectorQuadVertices[vertexId];
    float2 px = instance.originPx + unit * instance.sizePx;
    px = slugGlyphApplyGestureZoom(px, uniforms);

    SlugGlyphVertexOut out;
    out.position = float4(vector_to_ndc(px, uniforms.surfaceSizePixels), 0.0, 1.0);
    out.glyphPoint = mix(instance.localMin, instance.localMax, unit);
    out.color = instance.color;
    out.glyphIndex = float(instance.glyphIndex);
    return out;
}

inline float2 slugGlyphSubpixelSample(float4 bounds, float2 uv, float2 center, float2 dx, float2 dy) {
    float x = mix(bounds.x, bounds.z, uv.x) - 0.5;
    float y = mix(bounds.y, bounds.w, uv.y) - 0.5;
    return center + x * dx + y * dy;
}

inline uint slugGlyphRootCode(float y1, float y2, float y3) {
    uint i1 = as_type<uint>(y1) >> 31u;
    uint i2 = as_type<uint>(y2) >> 30u;
    uint i3 = as_type<uint>(y3) >> 29u;
    uint shift = (i2 & 2u) | (i1 & ~2u);
    shift = (i3 & 4u) | (shift & ~4u);
    return ((0x2E74u >> shift) & 0x0101u);
}

inline float2 slugGlyphSolveHorizontal(VectorGlyphCurve curve) {
    float2 a = curve.p0 - curve.p1 * 2.0 + curve.p2;
    float2 b = curve.p0 - curve.p1;
    float ra = 1.0 / a.y;
    float rb = 0.5 / b.y;
    float d = sqrt(max(b.y * b.y - a.y * curve.p0.y, 0.0));
    float t1 = (b.y - d) * ra;
    float t2 = (b.y + d) * ra;
    if (abs(a.y) < 1.0 / 65536.0) {
        t1 = t2 = curve.p0.y * rb;
    }
    return float2(
        (a.x * t1 - b.x * 2.0) * t1 + curve.p0.x,
        (a.x * t2 - b.x * 2.0) * t2 + curve.p0.x);
}

inline float2 slugGlyphSolveVertical(VectorGlyphCurve curve) {
    float2 a = curve.p0 - curve.p1 * 2.0 + curve.p2;
    float2 b = curve.p0 - curve.p1;
    float ra = 1.0 / a.x;
    float rb = 0.5 / b.x;
    float d = sqrt(max(b.x * b.x - a.x * curve.p0.x, 0.0));
    float t1 = (b.x - d) * ra;
    float t2 = (b.x + d) * ra;
    if (abs(a.x) < 1.0 / 65536.0) {
        t1 = t2 = curve.p0.x * rb;
    }
    return float2(
        (a.y * t1 - b.y * 2.0) * t1 + curve.p0.y,
        (a.y * t2 - b.y * 2.0) * t2 + curve.p0.y);
}

inline float slugGlyphCombineCoverage(float xcov, float ycov, float xwgt, float ywgt) {
    float weighted = abs(xcov * xwgt + ycov * ywgt) / max(xwgt + ywgt, 1.0 / 65536.0);
    float coverage = max(weighted, min(abs(xcov), abs(ycov)));
    return clamp(coverage, 0.0, 1.0);
}

inline float slugGlyphReferenceCoverage(
    constant VectorGlyphCurve *curves,
    constant SlugGlyphBand *bands,
    constant uint *bandIndices,
    SlugGlyph glyph,
    float2 sample,
    float2 unitsPerPixel
) {
    unitsPerPixel = max(abs(unitsPerPixel), float2(1.0e-6));
    if (sample.x < glyph.boundsMin.x - unitsPerPixel.x ||
        sample.x > glyph.boundsMax.x + unitsPerPixel.x ||
        sample.y < glyph.boundsMin.y - unitsPerPixel.y ||
        sample.y > glyph.boundsMax.y + unitsPerPixel.y) {
        return 0.0;
    }

    float2 pixelsPerUnit = 1.0 / unitsPerPixel;
    float xcov = 0.0;
    float xwgt = 0.0;
    if (glyph.horizontalBandCount > 0) {
        float height = max(glyph.boundsMax.y - glyph.boundsMin.y, 1.0e-6);
        float normalizedY = clamp((sample.y - glyph.boundsMin.y) / height, 0.0, 0.999999);
        uint bandIndex = min(
            glyph.horizontalBandCount - 1,
            uint(floor(normalizedY * float(glyph.horizontalBandCount))));
        SlugGlyphBand band = bands[glyph.horizontalBandStart + bandIndex];
        for (uint i = 0; i < band.indexCount; i++) {
            uint curveIndex = bandIndices[band.indexStart + i];
            VectorGlyphCurve curve = curves[curveIndex];
            curve.p0 -= sample;
            curve.p1 -= sample;
            curve.p2 -= sample;
            if (max(max(curve.p0.x, curve.p1.x), curve.p2.x) * pixelsPerUnit.x < -0.5) {
                break;
            }
            uint code = slugGlyphRootCode(curve.p0.y, curve.p1.y, curve.p2.y);
            if (code != 0u) {
                float2 roots = slugGlyphSolveHorizontal(curve) * pixelsPerUnit.x;
                if ((code & 1u) != 0u) {
                    xcov += clamp(roots.x + 0.5, 0.0, 1.0);
                    xwgt = max(xwgt, clamp(1.0 - abs(roots.x) * 2.0, 0.0, 1.0));
                }
                if (code > 1u) {
                    xcov -= clamp(roots.y + 0.5, 0.0, 1.0);
                    xwgt = max(xwgt, clamp(1.0 - abs(roots.y) * 2.0, 0.0, 1.0));
                }
            }
        }
    }

    float ycov = 0.0;
    float ywgt = 0.0;
    if (glyph.verticalBandCount > 0) {
        float width = max(glyph.boundsMax.x - glyph.boundsMin.x, 1.0e-6);
        float normalizedX = clamp((sample.x - glyph.boundsMin.x) / width, 0.0, 0.999999);
        uint bandIndex = min(
            glyph.verticalBandCount - 1,
            uint(floor(normalizedX * float(glyph.verticalBandCount))));
        SlugGlyphBand band = bands[glyph.verticalBandStart + bandIndex];
        for (uint i = 0; i < band.indexCount; i++) {
            uint curveIndex = bandIndices[band.indexStart + i];
            VectorGlyphCurve curve = curves[curveIndex];
            curve.p0 -= sample;
            curve.p1 -= sample;
            curve.p2 -= sample;
            if (max(max(curve.p0.y, curve.p1.y), curve.p2.y) * pixelsPerUnit.y < -0.5) {
                break;
            }
            uint code = slugGlyphRootCode(curve.p0.x, curve.p1.x, curve.p2.x);
            if (code != 0u) {
                float2 roots = slugGlyphSolveVertical(curve) * pixelsPerUnit.y;
                if ((code & 1u) != 0u) {
                    ycov -= clamp(roots.x + 0.5, 0.0, 1.0);
                    ywgt = max(ywgt, clamp(1.0 - abs(roots.x) * 2.0, 0.0, 1.0));
                }
                if (code > 1u) {
                    ycov += clamp(roots.y + 0.5, 0.0, 1.0);
                    ywgt = max(ywgt, clamp(1.0 - abs(roots.y) * 2.0, 0.0, 1.0));
                }
            }
        }
    }

    return slugGlyphCombineCoverage(xcov, ycov, xwgt, ywgt);
}

fragment float4 slugGlyphBandFragment(
    SlugGlyphVertexOut in [[stage_in]],
    constant SlugGlyphUniforms &uniforms [[buffer(4)]],
    constant VectorGlyphCurve *curves [[buffer(0)]],
    constant SlugGlyph *glyphs [[buffer(1)]],
    constant SlugGlyphBand *bands [[buffer(2)]],
    constant uint *bandIndices [[buffer(3)]]
) {
    uint glyphIndex = uint(in.glyphIndex + 0.5);
    SlugGlyph glyph = glyphs[glyphIndex];
    float2 dx = dfdx(in.glyphPoint);
    float2 dy = dfdy(in.glyphPoint);
    float2 unitsPerPixel = fwidth(in.glyphPoint);
    if (uniforms.subpixelMode == 0) {
        float2 sample = slugGlyphSubpixelSample(
            uniforms.subpixelGBounds, float2(0.5, 0.5), in.glyphPoint, dx, dy);
        float coverage = slugGlyphReferenceCoverage(
            curves, bands, bandIndices, glyph, sample, unitsPerPixel);
        float alpha = coverage * in.color.a;
        return float4(in.color.rgb * alpha, alpha);
    }

    float r = slugGlyphReferenceCoverage(
        curves, bands, bandIndices, glyph,
        slugGlyphSubpixelSample(uniforms.subpixelRBounds, float2(0.5, 0.5), in.glyphPoint, dx, dy),
        unitsPerPixel);
    float g = slugGlyphReferenceCoverage(
        curves, bands, bandIndices, glyph,
        slugGlyphSubpixelSample(uniforms.subpixelGBounds, float2(0.5, 0.5), in.glyphPoint, dx, dy),
        unitsPerPixel);
    float b = slugGlyphReferenceCoverage(
        curves, bands, bandIndices, glyph,
        slugGlyphSubpixelSample(uniforms.subpixelBBounds, float2(0.5, 0.5), in.glyphPoint, dx, dy),
        unitsPerPixel);
    float3 coverage = float3(r, g, b);
    float alpha = max(max(r, g), b) * in.color.a;
    return float4(in.color.rgb * coverage * in.color.a, alpha);
}
