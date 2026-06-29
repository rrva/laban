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
/// The whole string is rasterized in a single coverage pass over one combined
/// outline: every glyph is translated to its CoreText pen position and merged
/// into one outline, then sampled once against a shared baseline grid. Baking
/// glyphs independently (each into its own bounding box, composited with
/// per-glyph rounding) made round digits anchor a pixel higher than flat-top
/// ones and snapped each glyph to a different sub-pixel phase — visible as
/// baseline wobble and blur. A single pass keeps the baseline straight and the
/// sub-pixel positioning exact.
///
/// Built for low-cardinality, frequently-repeated strings: the finished image is
/// memoized by `(text, font, color, scale)`, so the pill re-showing a number it
/// rendered moments ago pays nothing. CoreText path extraction is itself cached
/// per glyph in `GlyphCurveStore`.
public final class VectorTextRasterizer {
  private struct ImageKey: Hashable {
    let text: String
    let fontKey: String
    let colorBits: UInt32
    let scaleBits: UInt64
  }

  // Supersampling factor per axis for antialiasing: the scratch kernel produces
  // hard 0/1 coverage, so each device pixel is averaged over a 4×4 = 16-sample
  // grid. 4× is the usual quality/cost knee for text-sized glyphs.
  private static let supersample = 4

  private let store = GlyphCurveStore()
  private let rasterizer: VectorGlyphScratchRasterizer
  private var imageCache: [ImageKey: CGImage] = [:]
  private let imageCacheLimit = 256
  private let srgb = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

  // Test seam: counts GPU rasterization passes actually run (cache misses). A
  // repeated string must stop incrementing this after its first render.
  private(set) var rasterizePassCount = 0

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

    let tint = srgbComponents(color)
    let key = ImageKey(
      text: text,
      fontKey: fontIdentity(font),
      colorBits: packColor(tint),
      scaleBits: (deviceScale * 256).rounded().bitPattern)
    if let cached = imageCache[key] { return cached }

    guard let image = renderImage(text: text, font: font, scale: deviceScale, tint: tint) else {
      return nil
    }
    if imageCache.count >= imageCacheLimit {
      imageCache.removeAll(keepingCapacity: true)
    }
    imageCache[key] = image
    return image
  }

  private func renderImage(
    text: String,
    font: CTFont,
    scale: CGFloat,
    tint: (r: Float, g: Float, b: Float, a: Float)
  ) -> CGImage? {
    let attributes = [kCTFontAttributeName: font] as CFDictionary
    guard let attributed = CFAttributedStringCreate(nil, text as CFString, attributes) else {
      return nil
    }
    let line = CTLineCreateWithAttributedString(attributed)

    var ascent: CGFloat = 0
    var descent: CGFloat = 0
    var leading: CGFloat = 0
    let typographicWidth = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
    let pointWidth = max(1, ceil(typographicWidth))
    let pointHeight = max(1, ceil(ascent + descent))
    let pixelWidth = max(1, Int((pointWidth * scale).rounded()))
    let pixelHeight = max(1, Int((pointHeight * scale).rounded()))

    guard let combined = combinedOutline(line: line, fallback: font) else { return nil }

    // The GPU scratch kernel is single-sample (one winding test per pixel center,
    // hard 0/1 coverage), so a direct device-scale raster is aliased. Rasterize
    // `Self.supersample`× denser and box-downsample, turning each device pixel
    // into an average over an SS×SS sample grid — that is the antialiasing.
    let ss = Self.supersample
    let superWidth = pixelWidth * ss
    let superHeight = pixelHeight * ss
    // One pass over the whole string: origin maps the bottom of the image to the
    // descent line, so the baseline (glyph-space y = 0) lands on the same row for
    // every glyph. The shader's per-pixel bounds early-out uses the outline's
    // tight ink bounds, so empty rows stay cheap despite the full-string extent.
    guard
      let superCoverage = rasterizer.rasterize(
        outline: combined,
        width: superWidth,
        height: superHeight,
        origin: CGPoint(x: 0, y: -descent),
        rasterScale: scale * CGFloat(ss))
    else { return nil }
    rasterizePassCount += 1

    let coverage = downsample(
      superCoverage,
      superWidth: superWidth,
      width: pixelWidth,
      height: pixelHeight,
      factor: ss)

    var rgba = [UInt8](repeating: 0, count: pixelWidth * pixelHeight * 4)
    var covered = false
    for index in 0..<(pixelWidth * pixelHeight) {
      let cov = coverage[index]
      guard cov > 0 else { continue }
      let srcA = tint.a * cov
      guard srcA > 0 else { continue }
      covered = true
      // Destination starts transparent, so the source-over result is just the
      // premultiplied source: rgb already folds in coverage via srcA.
      let pixel = index * 4
      rgba[pixel] = clampByte(tint.r * srcA * 255)
      rgba[pixel + 1] = clampByte(tint.g * srcA * 255)
      rgba[pixel + 2] = clampByte(tint.b * srcA * 255)
      rgba[pixel + 3] = clampByte(srcA * 255)
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

  /// Merge every glyph in the line into one outline, each translated to its pen
  /// position, with a tight ink bounds union for the rasterizer's early-out.
  /// Returns nil if no glyph contributed a fillable contour.
  private func combinedOutline(line: CTLine, fallback: CTFont) -> GlyphCurveOutline? {
    guard let runs = CTLineGetGlyphRuns(line) as? [CTRun] else { return nil }
    var curves: [GlyphQuadraticCurve] = []
    var contours: [GlyphContour] = []
    var minX = CGFloat.infinity
    var minY = CGFloat.infinity
    var maxX = -CGFloat.infinity
    var maxY = -CGFloat.infinity

    for run in runs {
      let runFont = runFont(of: run, fallback: fallback)
      let glyphCount = CTRunGetGlyphCount(run)
      guard glyphCount > 0 else { continue }
      var glyphs = [CGGlyph](repeating: 0, count: glyphCount)
      var positions = [CGPoint](repeating: .zero, count: glyphCount)
      CTRunGetGlyphs(run, CFRangeMake(0, glyphCount), &glyphs)
      CTRunGetPositions(run, CFRangeMake(0, glyphCount), &positions)

      for index in 0..<glyphCount {
        guard let outline = store.outline(for: glyphs[index], font: runFont) else { continue }
        let offset = positions[index]
        let base = curves.count
        for curve in outline.curves {
          let moved = GlyphQuadraticCurve(
            p0: translate(curve.p0, by: offset),
            p1: translate(curve.p1, by: offset),
            p2: translate(curve.p2, by: offset))
          curves.append(moved)
          for point in [moved.p0, moved.p1, moved.p2] {
            minX = min(minX, point.x)
            minY = min(minY, point.y)
            maxX = max(maxX, point.x)
            maxY = max(maxY, point.y)
          }
        }
        for contour in outline.contours {
          contours.append(
            GlyphContour(
              seed: translate(contour.seed, by: offset),
              curveStart: base + contour.curveStart,
              curveCount: contour.curveCount))
        }
      }
    }

    guard !curves.isEmpty, !contours.isEmpty, minX.isFinite, maxX > minX, maxY > minY else {
      return nil
    }
    return GlyphCurveOutline(
      glyph: 0,
      bounds: CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY),
      curves: curves,
      contours: contours)
  }

  private func translate(_ point: CGPoint, by offset: CGPoint) -> CGPoint {
    CGPoint(x: point.x + offset.x, y: point.y + offset.y)
  }

  /// Box-downsample a supersampled r8 coverage buffer to device resolution: each
  /// output pixel is the mean of its `factor`×`factor` source samples, in [0, 1].
  private func downsample(
    _ source: [UInt8],
    superWidth: Int,
    width: Int,
    height: Int,
    factor: Int
  ) -> [Float] {
    var out = [Float](repeating: 0, count: width * height)
    let inverse = 1.0 / Float(factor * factor)
    for y in 0..<height {
      let srcRowBase = y * factor * superWidth
      for x in 0..<width {
        let srcColBase = x * factor
        var sum = 0
        for sy in 0..<factor {
          let rowBase = srcRowBase + sy * superWidth + srcColBase
          for sx in 0..<factor {
            sum += Int(source[rowBase + sx])
          }
        }
        out[y * width + x] = Float(sum) * inverse / 255.0
      }
    }
    return out
  }

  private func runFont(of run: CTRun, fallback: CTFont) -> CTFont {
    let attributes = CTRunGetAttributes(run) as NSDictionary
    guard let raw = attributes[kCTFontAttributeName as String] else { return fallback }
    return raw as! CTFont
  }

  private func fontIdentity(_ font: CTFont) -> String {
    let name = (CTFontCopyPostScriptName(font) as String)
    let size = CTFontGetSize(font)
    return "\(name)@\(size)"
  }

  private func clampByte(_ value: Float) -> UInt8 {
    UInt8(max(0, min(255, value.rounded())))
  }

  private func packColor(_ tint: (r: Float, g: Float, b: Float, a: Float)) -> UInt32 {
    func channel(_ value: Float) -> UInt32 {
      UInt32(max(0, min(255, (value * 255).rounded())))
    }
    return (channel(tint.a) << 24) | (channel(tint.r) << 16) | (channel(tint.g) << 8)
      | channel(tint.b)
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
