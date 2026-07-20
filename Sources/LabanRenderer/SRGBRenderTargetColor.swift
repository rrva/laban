import Metal

/// Color conversions for curve renderers that composite in linear light.
///
/// Opaque Vector/Slug surfaces render directly into an sRGB target, whose store
/// conversion preserves these linear values and whose fixed-function blends run
/// in linear light. Nonopaque surfaces instead retain these values in a
/// linear-premultiplied float target; a separate final resolve owns the one
/// encoded-sRGB-premultiplication boundary needed by Core Animation.
public enum SRGBRenderTargetColor {
  @inline(__always)
  public static func linearizedStraightRGBA(_ rgba: UInt32) -> SIMD4<Float> {
    SIMD4<Float>(
      linearize(Float((rgba >> 24) & 0xFF) / 255),
      linearize(Float((rgba >> 16) & 0xFF) / 255),
      linearize(Float((rgba >> 8) & 0xFF) / 255),
      Float(rgba & 0xFF) / 255)
  }

  /// Inverse of `linearizedStraightRGBA`: convert a linear-light straight
  /// RGBA value to a packed `0xRRGGBBAA` encoded-sRGB value. Used by tests
  /// and debug readback to compare GPU output against expected encoded values.
  @inline(__always)
  public static func encodedSRGBA(_ linear: SIMD4<Float>) -> UInt32 {
    func encode(_ component: Float) -> UInt8 {
      let clamped = max(0, min(1, component))
      let encoded =
        clamped <= 0.0031308
        ? clamped * 12.92
        : 1.055 * pow(clamped, 1 / 2.4) - 0.055
      return UInt8((encoded * 255).rounded())
    }
    let r = encode(linear.x)
    let g = encode(linear.y)
    let b = encode(linear.z)
    let a = UInt8((max(0, min(1, linear.w)) * 255).rounded())
    return (UInt32(r) << 24) | (UInt32(g) << 16) | (UInt32(b) << 8) | UInt32(a)
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
