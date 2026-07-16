import Metal

/// Color conversions for curve renderers that composite in linear light.
///
/// Opaque Vector/Slug surfaces render directly into an sRGB target, whose store
/// conversion preserves these linear values and whose fixed-function blends run
/// in linear light. Nonopaque surfaces instead retain these values in a
/// linear-premultiplied float target; a separate final resolve owns the one
/// encoded-sRGB-premultiplication boundary needed by Core Animation.
enum SRGBRenderTargetColor {
  @inline(__always)
  static func linearizedStraightRGBA(_ rgba: UInt32) -> SIMD4<Float> {
    SIMD4<Float>(
      linearize(Float((rgba >> 24) & 0xFF) / 255),
      linearize(Float((rgba >> 16) & 0xFF) / 255),
      linearize(Float((rgba >> 8) & 0xFF) / 255),
      Float(rgba & 0xFF) / 255)
  }

  /// Linear-premultiplied clear matching the first terminal replace canvas.
  /// `MetalRenderer.fullRedrawClearColor` already returns encoded-sRGB values
  /// premultiplied by alpha; recover its straight encoded color, linearize it,
  /// then premultiply in the working space. The alpha-one case reduces to the
  /// exact shipped opaque clear conversion.
  static func linearPremultipliedClearColor(
    _ commands: [FrameCommand]
  ) -> MTLClearColor {
    let color = MetalRenderer.fullRedrawClearColor(commands)
    guard color.alpha > 0 else {
      return MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
    }
    let alpha = Float(color.alpha)
    return MTLClearColor(
      red: Double(linearize(Float(color.red) / alpha) * alpha),
      green: Double(linearize(Float(color.green) / alpha) * alpha),
      blue: Double(linearize(Float(color.blue) / alpha) * alpha),
      alpha: color.alpha)
  }

  @inline(__always)
  static func linearize(_ component: Float) -> Float {
    component <= 0.04045
      ? component / 12.92
      : pow((component + 0.055) / 1.055, 2.4)
  }
}
