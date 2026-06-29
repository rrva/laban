import CoreGraphics
import CoreText
import Foundation
import Metal

/// Rasterizes short strings into images through the vector glyph pipeline
/// (CoreText outline extraction → GPU coverage rasterization), so chrome that
/// lives outside the terminal grid (e.g. the scrollback pill) can render its
/// text with the same curve-based glyphs as the on-screen text when the vector
/// renderer is active, instead of CoreText/CATextLayer.
///
/// Built for low-cardinality, frequently-repeated strings: the per-glyph
/// coverage mask is memoized by `(font, glyph, device scale)`, so once each
/// distinct glyph has been baked, steady-state re-rendering of a changing
/// number (the pill's "<rows>/<total>") only pays CPU compositing — no GPU
/// round-trip per tick. That keeps it within the overlay's existing
/// update-on-text-change budget rather than regressing scroll cadence.
public final class VectorTextRasterizer {
  private struct MaskKey: Hashable {
    // A stable font identity (PostScript name + size), not ObjectIdentifier:
    // each CTLine re-wraps the font as a distinct CTFont instance, so object
    // identity would miss the cache on every re-render of the same text.
    let fontKey: String
    let glyph: CGGlyph
    let scaleBits: UInt64
  }

  private struct GlyphMask {
    let bytes: [UInt8]
    let width: Int
    let height: Int
    let boundsMin: CGPoint
    let boundsMax: CGPoint
  }

  private let store = GlyphCurveStore()
  private let rasterizer: VectorGlyphScratchRasterizer
  private var maskCache: [MaskKey: GlyphMask?] = [:]
  private let srgb = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

  // Test seam: counts distinct glyph masks actually baked on the GPU (cache
  // misses). A repeated glyph must stop incrementing this after its first bake.
  private(set) var glyphBakeCount = 0

  public init?(device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
    guard let rasterizer = VectorGlyphScratchRasterizer(device: device) else { return nil }
    self.rasterizer = rasterizer
  }

  /// Rasterize `text` laid out in `font` into a premultiplied sRGB image at
  /// `scale` device pixels per point, tinted by `color`. Returns nil when the
  /// string is empty or no glyph in it produced a fillable outline (e.g. only
  /// whitespace), so the caller can fall back to its non-vector text path.
  public func image(
    for text: String,
    font: CTFont,
    color: CGColor,
    scale: CGFloat
  ) -> CGImage? {
    guard !text.isEmpty else { return nil }
    let deviceScale = max(scale, 1)
    guard deviceScale.isFinite else { return nil }

    let attributes = [kCTFontAttributeName: font] as CFDictionary
    guard
      let attributed = CFAttributedStringCreate(nil, text as CFString, attributes)
    else { return nil }
    let line = CTLineCreateWithAttributedString(attributed)

    var ascent: CGFloat = 0
    var descent: CGFloat = 0
    var leading: CGFloat = 0
    let typographicWidth = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
    let pointWidth = max(1, ceil(typographicWidth))
    let pointHeight = max(1, ceil(ascent + descent))
    let pixelWidth = max(1, Int((pointWidth * deviceScale).rounded()))
    let pixelHeight = max(1, Int((pointHeight * deviceScale).rounded()))

    let tint = srgbComponents(color)
    var rgba = [UInt8](repeating: 0, count: pixelWidth * pixelHeight * 4)
    var covered = false

    guard let runs = CTLineGetGlyphRuns(line) as? [CTRun] else { return nil }
    for run in runs {
      let runFont = runFont(of: run, fallback: font)
      let glyphCount = CTRunGetGlyphCount(run)
      guard glyphCount > 0 else { continue }
      var glyphs = [CGGlyph](repeating: 0, count: glyphCount)
      var positions = [CGPoint](repeating: .zero, count: glyphCount)
      CTRunGetGlyphs(run, CFRangeMake(0, glyphCount), &glyphs)
      CTRunGetPositions(run, CFRangeMake(0, glyphCount), &positions)

      for index in 0..<glyphCount {
        guard let mask = mask(for: glyphs[index], font: runFont, scale: deviceScale) else {
          continue
        }
        let position = positions[index]
        // Baseline sits `descent` points above the image bottom. The mask's
        // top-left in image point-space is the glyph's pen origin plus the
        // outline's top-left corner; convert to top-down pixel rows.
        let destLeft = (position.x + mask.boundsMin.x) * deviceScale
        let destTop =
          (pointHeight - (descent + position.y + mask.boundsMax.y)) * deviceScale
        let destLeftPx = Int(destLeft.rounded())
        let destTopPx = Int(destTop.rounded())
        if composite(
          mask: mask,
          destLeftPx: destLeftPx,
          destTopPx: destTopPx,
          into: &rgba,
          imageWidth: pixelWidth,
          imageHeight: pixelHeight,
          tint: tint)
        {
          covered = true
        }
      }
    }

    guard covered else { return nil }
    guard
      let context = CGContext(
        data: &rgba,
        width: pixelWidth,
        height: pixelHeight,
        bitsPerComponent: 8,
        bytesPerRow: pixelWidth * 4,
        space: srgb,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    return context.makeImage()
  }

  private func runFont(of run: CTRun, fallback: CTFont) -> CTFont {
    let attributes = CTRunGetAttributes(run) as NSDictionary
    guard let raw = attributes[kCTFontAttributeName as String] else { return fallback }
    return raw as! CTFont
  }

  private func mask(for glyph: CGGlyph, font: CTFont, scale: CGFloat) -> GlyphMask? {
    let key = MaskKey(
      fontKey: fontIdentity(font),
      glyph: glyph,
      scaleBits: (scale * 256).rounded().bitPattern)
    if let cached = maskCache[key] { return cached }
    let built = bake(glyph: glyph, font: font, scale: scale)
    maskCache[key] = built
    return built
  }

  private func fontIdentity(_ font: CTFont) -> String {
    let name = (CTFontCopyPostScriptName(font) as String)
    let size = CTFontGetSize(font)
    return "\(name)@\(size)"
  }

  private func bake(glyph: CGGlyph, font: CTFont, scale: CGFloat) -> GlyphMask? {
    guard let outline = store.outline(for: glyph, font: font) else { return nil }
    let bounds = outline.bounds
    guard bounds.width > 0, bounds.height > 0 else { return nil }
    let width = max(1, Int(ceil(bounds.width * scale)))
    let height = max(1, Int(ceil(bounds.height * scale)))
    guard
      let bytes = rasterizer.rasterize(
        outline: outline,
        width: width,
        height: height,
        origin: CGPoint(x: bounds.minX, y: bounds.minY),
        rasterScale: scale)
    else { return nil }
    glyphBakeCount += 1
    return GlyphMask(
      bytes: bytes,
      width: width,
      height: height,
      boundsMin: CGPoint(x: bounds.minX, y: bounds.minY),
      boundsMax: CGPoint(x: bounds.maxX, y: bounds.maxY))
  }

  /// Source-over composite a coverage mask into the premultiplied destination.
  /// Returns true if any pixel received non-zero coverage.
  private func composite(
    mask: GlyphMask,
    destLeftPx: Int,
    destTopPx: Int,
    into rgba: inout [UInt8],
    imageWidth: Int,
    imageHeight: Int,
    tint: (r: Float, g: Float, b: Float, a: Float)
  ) -> Bool {
    var touched = false
    for my in 0..<mask.height {
      let destY = destTopPx + my
      guard destY >= 0, destY < imageHeight else { continue }
      let rowBase = destY * imageWidth * 4
      let maskRowBase = my * mask.width
      for mx in 0..<mask.width {
        let coverage = Float(mask.bytes[maskRowBase + mx]) / 255.0
        guard coverage > 0 else { continue }
        let destX = destLeftPx + mx
        guard destX >= 0, destX < imageWidth else { continue }
        let srcA = tint.a * coverage
        guard srcA > 0 else { continue }
        touched = true
        let inv = 1 - srcA
        let pixel = rowBase + destX * 4
        // Premultiplied over: out = src*1 + dst*(1 - srcA); src is already
        // premultiplied because srcA folds the coverage into the alpha.
        rgba[pixel] = clampByte(tint.r * srcA * 255 + Float(rgba[pixel]) * inv)
        rgba[pixel + 1] = clampByte(tint.g * srcA * 255 + Float(rgba[pixel + 1]) * inv)
        rgba[pixel + 2] = clampByte(tint.b * srcA * 255 + Float(rgba[pixel + 2]) * inv)
        rgba[pixel + 3] = clampByte(srcA * 255 + Float(rgba[pixel + 3]) * inv)
      }
    }
    return touched
  }

  private func clampByte(_ value: Float) -> UInt8 {
    UInt8(max(0, min(255, value.rounded())))
  }

  private func srgbComponents(_ color: CGColor) -> (r: Float, g: Float, b: Float, a: Float) {
    if let converted = color.converted(to: srgb, intent: .defaultIntent, options: nil),
      let components = converted.components, components.count >= 4
    {
      return (
        Float(components[0]), Float(components[1]), Float(components[2]), Float(components[3])
      )
    }
    if let components = color.components {
      if components.count >= 4 {
        return (
          Float(components[0]), Float(components[1]), Float(components[2]), Float(components[3])
        )
      }
      if components.count == 2 {
        let gray = Float(components[0])
        return (gray, gray, gray, Float(components[1]))
      }
    }
    return (0, 0, 0, 1)
  }
}
