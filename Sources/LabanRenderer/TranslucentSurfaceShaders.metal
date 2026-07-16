#include <metal_stdlib>
using namespace metal;

// Kept in a separate lazily compiled library so an always-opaque Vector or
// Slug activation compiles the exact shipped VectorGlyphShaders source and PSO
// set. The vertex output layout matches `VectorVertexOut` in that library;
// Metal links the fragment with `vectorGlyphVertex` by stage attributes.
struct TranslucentVectorVertexOut {
    float4 position [[position]];
    float4 color;
    float2 uv;
};

fragment float4 translucentVectorGlyphAlphaFragment(
    TranslucentVectorVertexOut in [[stage_in]],
    texture2d<float> atlas [[texture(0)]],
    sampler atlasSampler [[sampler(0)]]
) {
    float coverage = atlas.sample(atlasSampler, in.uv).r;
    float alpha = in.color.a * coverage;
    return float4(in.color.rgb * alpha, alpha);
}

struct TranslucentFullscreenOut {
    float4 position [[position]];
};

inline float translucent_srgb_to_linear(float c) {
    return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4);
}

inline float translucent_linear_to_srgb(float c) {
    return c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1.0 / 2.4) - 0.055;
}

// ColorGlyphAtlas is populated by a premultiplied-first Core Graphics bitmap,
// then uploaded unchanged into a nonsRGB BGRA texture. Recover its straight
// encoded-sRGB color before linearizing, then premultiply exactly once in the
// linear working representation. The opaque fragment intentionally remains in
// VectorGlyphShaders.metal so this correction cannot alter the shipped path.
fragment float4 translucentVectorColorGlyphFragment(
    TranslucentVectorVertexOut in [[stage_in]],
    texture2d<float> atlas [[texture(0)]],
    sampler atlasSampler [[sampler(0)]]
) {
    float4 encodedPremultiplied = saturate(atlas.sample(atlasSampler, in.uv));
    float alpha = encodedPremultiplied.a;
    if (alpha <= 0.0) {
        return float4(0.0);
    }
    float3 straightSRGB = saturate(encodedPremultiplied.rgb / alpha);
    float3 straightLinear = float3(
        translucent_srgb_to_linear(straightSRGB.r),
        translucent_srgb_to_linear(straightSRGB.g),
        translucent_srgb_to_linear(straightSRGB.b));
    return float4(straightLinear * alpha, alpha);
}

// Resolve a linear-premultiplied working target into the encoded-sRGB-
// premultiplied storage Core Animation requires for a nonopaque surface. The
// destination is bgra8Unorm_srgb, so return linear(sRGB * alpha); the attachment
// applies its normal sRGB encoding on store and the resulting bytes are exactly
// sRGB * alpha.
fragment float4 linearPremultipliedResolveFragment(
    TranslucentFullscreenOut in [[stage_in]],
    texture2d<float, access::read> source [[texture(0)]]
) {
    uint2 coordinate = uint2(in.position.xy);
    float4 premultiplied = source.read(coordinate);
    float alpha = saturate(premultiplied.a);
    if (alpha <= 0.0) {
        return float4(0.0);
    }
    float3 straightLinear = saturate(premultiplied.rgb / alpha);
    float3 straightSRGB = float3(
        translucent_linear_to_srgb(straightLinear.r),
        translucent_linear_to_srgb(straightLinear.g),
        translucent_linear_to_srgb(straightLinear.b));
    float3 encodedPremultiplied = straightSRGB * alpha;
    return float4(
        translucent_srgb_to_linear(encodedPremultiplied.r),
        translucent_srgb_to_linear(encodedPremultiplied.g),
        translucent_srgb_to_linear(encodedPremultiplied.b),
        alpha);
}
