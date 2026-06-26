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
};

struct VectorRenderUniforms {
    float2 surfaceSizePixels;
    float scale;
    float _pad;
};

struct VectorVertexOut {
    float4 position [[position]];
    float4 color;
    float2 uv;
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

vertex VectorVertexOut vectorSolidVertex(
    uint vertexId [[vertex_id]],
    uint instanceId [[instance_id]],
    constant VectorSolidInstance *instances [[buffer(0)]],
    constant VectorRenderUniforms &uniforms [[buffer(1)]]
) {
    VectorSolidInstance instance = instances[instanceId];
    float2 unit = kVectorQuadVertices[vertexId];
    float2 px = instance.origin + unit * instance.size;

    VectorVertexOut out;
    out.position = float4(vector_to_ndc(px, uniforms.surfaceSizePixels), 0.0, 1.0);
    out.color = instance.color;
    out.uv = float2(0.0, 0.0);
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

    VectorVertexOut out;
    out.position = float4(vector_to_ndc(px, uniforms.surfaceSizePixels), 0.0, 1.0);
    out.color = instance.color;
    out.uv = float2(
        instance.uvOrigin.x + unit.x * instance.uvSize.x,
        instance.uvOrigin.y + (1.0 - unit.y) * instance.uvSize.y
    );
    return out;
}

fragment float4 vectorGlyphCoverageFragment(
    VectorVertexOut in [[stage_in]],
    texture2d<float> atlas [[texture(0)]],
    sampler atlasSampler [[sampler(0)]]
) {
    return float4(atlas.sample(atlasSampler, in.uv).rgb * in.color.a, 0.0);
}

fragment float4 vectorGlyphColorFragment(
    VectorVertexOut in [[stage_in]],
    texture2d<float> atlas [[texture(0)]],
    sampler atlasSampler [[sampler(0)]]
) {
    float3 coverage = atlas.sample(atlasSampler, in.uv).rgb;
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

fragment float4 vectorColorGlyphFragment(
    VectorVertexOut in [[stage_in]],
    texture2d<float> atlas [[texture(0)]],
    sampler atlasSampler [[sampler(0)]]
) {
    float4 sample = atlas.sample(atlasSampler, in.uv);
    return float4(sample.rgb * sample.a, sample.a);
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
        float derivative = -2.0 * b;
        if (derivative < -eps) {
            return 1;
        }
        if (derivative > eps) {
            return -1;
        }
        return 0;
    }

    float discriminant = b * b - a * c;
    if (discriminant <= eps) {
        return 0;
    }

    float root = sqrt(discriminant);
    float t0 = (b - root) / a;
    float t1 = (b + root) / a;
    int winding = 0;
    if (valid_root(t0, curve)) {
        winding += 1;
    }
    if (valid_root(t1, curve)) {
        winding -= 1;
    }
    return winding;
}

inline float window_weight(float x, float halfWidth) {
    return clamp((x + halfWidth) / (2.0 * halfWidth), 0.0, 1.0);
}

inline float winding_window_contribution(VectorGlyphCurve curve, float halfWidth) {
    constexpr float eps = 1.0e-6;
    float y0 = curve.p0.y;
    float y1 = curve.p1.y;
    float y2 = curve.p2.y;
    float a = y0 - 2.0 * y1 + y2;
    float b = y0 - y1;
    float c = y0;

    if (fabs(a) <= eps) {
        if (fabs(b) <= eps) {
            return 0.0;
        }
        float t = c / (2.0 * b);
        if (t < -eps || t >= 1.0 - eps) {
            return 0.0;
        }
        float clamped = clamp(t, 0.0, 1.0);
        float x = curve_x_at(curve, clamped);
        if (x < -halfWidth - eps) {
            return 0.0;
        }
        float derivative = -2.0 * b;
        if (derivative < -eps) {
            return window_weight(x, halfWidth);
        }
        if (derivative > eps) {
            return -window_weight(x, halfWidth);
        }
        return 0.0;
    }

    float discriminant = b * b - a * c;
    if (discriminant <= eps) {
        return 0.0;
    }

    float root = sqrt(discriminant);
    float t0 = (b - root) / a;
    float t1 = (b + root) / a;
    float winding = 0.0;
    if (t0 >= -eps && t0 < 1.0 - eps) {
        float x = curve_x_at(curve, clamp(t0, 0.0, 1.0));
        if (x >= -halfWidth - eps) {
            winding += window_weight(x, halfWidth);
        }
    }
    if (t1 >= -eps && t1 < 1.0 - eps) {
        float x = curve_x_at(curve, clamp(t1, 0.0, 1.0));
        if (x >= -halfWidth - eps) {
            winding -= window_weight(x, halfWidth);
        }
    }
    return winding;
}

inline float vector_r2(uint index, uint seed, float alpha, uint shift) {
    uint mixed = seed ^ (seed >> shift);
    float seedOffset = float(mixed & 0xffffu) / 65536.0;
    return fract((float(index) + 0.5) * alpha + seedOffset);
}

inline float vector_coverage_at(
    constant VectorGlyphCurve *curves,
    uint curveCount,
    float2 sample,
    float2 boundsMin,
    float2 boundsMax,
    float halfWidth
) {
    if (sample.x < boundsMin.x - halfWidth || sample.x > boundsMax.x + halfWidth ||
        sample.y < boundsMin.y || sample.y > boundsMax.y) {
        return 0.0;
    }

    float winding = 0.0;
    for (uint i = 0; i < curveCount; i++) {
        VectorGlyphCurve curve = curves[i];
        curve.p0 -= sample;
        curve.p1 -= sample;
        curve.p2 -= sample;
        winding += winding_window_contribution(curve, halfWidth);
    }
    return clamp(float(abs(winding)), 0.0, 1.0);
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
        output.write(float4(0.0, 0.0, 0.0, 1.0), gid);
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
    float2 pixelBase = float2(
        float(gid.x),
        float(params.height - 1 - gid.y)
    );
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
    resolved.write(float4(clamp(alpha, 0.0, 1.0), 1.0), atlasPosition);
}
