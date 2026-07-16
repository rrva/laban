import Metal

/// Color conversions for renderers whose final target is an sRGB Metal texture.
///
/// Metal linearizes RGB on load and encodes it again on store. That is the
/// right behavior for opaque colors and for source-over blending in linear
/// light, but a nonopaque texture consumed by Core Animation has one additional
/// storage constraint: its encoded RGB bytes must be premultiplied by alpha.
/// Premultiplying *after* linearization stores `encode(linear(sRGB) * alpha)`,
/// whose bright channels can exceed alpha and are then clipped during Core
/// Animation's straight-color recovery. Alpha-bearing replacement pixels must
/// instead store `sRGB * alpha`, expressed to Metal as
/// `linear(sRGB * alpha)`.
enum SRGBRenderTargetColor {
  @inline(__always)
  static func linearizedStraightRGBA(_ rgba: UInt32) -> SIMD4<Float> {
    SIMD4<Float>(
      linearize(Float((rgba >> 24) & 0xFF) / 255),
      linearize(Float((rgba >> 16) & 0xFF) / 255),
      linearize(Float((rgba >> 8) & 0xFF) / 255),
      Float(rgba & 0xFF) / 255)
  }

  /// Instance color for `vectorSolidFragment`, which multiplies RGB by alpha.
  /// The returned straight-like RGB makes that fragment emit
  /// `linear(sRGB * alpha)` for encoded-premultiplied target storage.
  @inline(__always)
  static func linearizedEncodedPremultipliedSolidRGBA(_ rgba: UInt32) -> SIMD4<Float> {
    let alpha = Float(rgba & 0xFF) / 255
    guard alpha > 0 else { return .zero }
    return SIMD4<Float>(
      linearize(Float((rgba >> 24) & 0xFF) / 255 * alpha) / alpha,
      linearize(Float((rgba >> 16) & 0xFF) / 255 * alpha) / alpha,
      linearize(Float((rgba >> 8) & 0xFF) / 255 * alpha) / alpha,
      alpha)
  }

  /// Clear value matching the encoded-premultiplied terminal canvas. The
  /// shared clear already contains `sRGB * alpha`; an sRGB attachment expects
  /// its clear components in linear space, so linearize those values directly.
  static func linearizedEncodedPremultipliedClearColor(
    _ commands: [FrameCommand]
  ) -> MTLClearColor {
    let color = MetalRenderer.fullRedrawClearColor(commands)
    return MTLClearColor(
      red: Double(linearize(Float(color.red))),
      green: Double(linearize(Float(color.green))),
      blue: Double(linearize(Float(color.blue))),
      alpha: color.alpha)
  }

  @inline(__always)
  static func linearize(_ component: Float) -> Float {
    component <= 0.04045
      ? component / 12.92
      : pow((component + 0.055) / 1.055, 2.4)
  }
}
