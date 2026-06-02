import CoreGraphics
import CoreText
import Foundation
import Metal
import MetalKit

/// GPU glyph atlas: a single R8 MTLTexture holding antialiased alpha masks
/// for every (character cluster, font, bold-fallback, italic-fallback)
/// tuple seen so far. Glyphs are packed with a simple shelf algorithm; the
/// texture grows only via fresh allocation on full (rare).
///
/// Color is *not* in the cache key — it's a tint applied per-instance in the
/// glyph fragment shader. That keeps the cache small and dense even when a
/// terminal uses thousands of unique foreground colors.
public final class MetalGlyphAtlas {

  public struct Entry {
    /// Logical pixel size of the glyph cell (in CG points × scale).
    public let pixelWidth: Int
    public let pixelHeight: Int
    /// Position in the atlas texture in pixels (top-left origin).
    public let originX: Int
    public let originY: Int
    /// Logical x offset, in CG points, where this tile starts relative to the
    /// terminal cell origin. Italic glyphs can have ink before x=0, so this
    /// value can be negative.
    public let logicalOriginX: CGFloat
    /// Logical (CG-points) tile width; matches the per-cell drawing width
    /// so wide CJK glyphs occupy two cells and italic-shifted glyphs reserve
    /// ink slop on either side.
    public let logicalWidth: CGFloat
  }

  private struct Key: Hashable {
    let text: String
    let font: ObjectIdentifier
    let boldFallback: Bool
    let italicFallback: Bool
  }

  // Single-scalar fast-path key. Terminal text is overwhelmingly one scalar
  // per cell, so keying the per-frame lookup on the integer scalar value skips
  // the `String(character)` allocation and SipHash string hashing the cluster
  // path pays per glyph per frame. Mirrors the font+glyph cache key strategy
  // used by GPU terminals (Ghostty improved exactly this hashing in 1.2.0).
  private struct ScalarKey: Hashable {
    let scalar: UInt32
    let font: ObjectIdentifier
    let boldFallback: Bool
    let italicFallback: Bool
  }

  // A/B toggle for the bench (MetalGlyphAtlasLookupBench). Production keeps the
  // fast path on; flipping it off forces the String-keyed lookup so the two can
  // be compared in one release binary.
  nonisolated(unsafe) public static var useScalarFastPath = true

  private enum RasterPlan {
    case glyph(CGGlyph, advance: CGFloat, bounds: CGRect)
    case line(CTLine, width: CGFloat, bounds: CGRect)

    var layoutWidth: CGFloat {
      switch self {
      case .glyph(_, let advance, _): return advance
      case .line(_, let width, _): return width
      }
    }

    var inkBounds: CGRect {
      switch self {
      case .glyph(_, _, let bounds): return bounds
      case .line(_, _, let bounds): return bounds
      }
    }
  }

  // Italic shear matches SoftwareRenderer's fake-italic transform. Positive
  // x shear makes glyph tops lean right in CoreGraphics' y-up coordinate space.
  private static let italicShear: CGFloat = 0.18

  private let device: MTLDevice
  public let texture: MTLTexture
  public let textureSize: Int

  private let scale: CGFloat
  private let cellWidth: CGFloat
  private let cellHeight: CGFloat
  private let descent: CGFloat
  private let colorSpace = CGColorSpaceCreateDeviceGray()

  private var entries: [Key: Entry] = [:]
  private var scalarEntries: [ScalarKey: Entry] = [:]
  private var glyphForScalar: [ObjectIdentifier: [UInt32: CGGlyph]] = [:]
  private var advanceForGlyph: [ObjectIdentifier: [CGGlyph: CGFloat]] = [:]
  private(set) var didOverflow = false

  // Shelf packer state.
  private var shelfX: Int = 0
  private var shelfY: Int = 0
  private var shelfHeight: Int = 0

  public init?(
    device: MTLDevice,
    cellWidth: CGFloat,
    cellHeight: CGFloat,
    descent: CGFloat,
    scale: CGFloat,
    textureSize: Int = 2048
  ) {
    self.device = device
    self.scale = max(scale, 1)
    self.cellWidth = cellWidth
    self.cellHeight = cellHeight
    self.descent = descent
    self.textureSize = textureSize

    let desc = MTLTextureDescriptor()
    desc.pixelFormat = .r8Unorm
    desc.width = textureSize
    desc.height = textureSize
    desc.usage = [.shaderRead]
    desc.storageMode = .shared
    guard let tex = device.makeTexture(descriptor: desc) else { return nil }
    self.texture = tex

    // Initialize to zero so unfilled regions are fully transparent.
    let zeros = [UInt8](repeating: 0, count: textureSize * textureSize)
    tex.replace(
      region: MTLRegionMake2D(0, 0, textureSize, textureSize),
      mipmapLevel: 0,
      withBytes: zeros,
      bytesPerRow: textureSize)
  }

  public func entry(
    scalar: Unicode.Scalar,
    font: CTFont,
    boldFallback: Bool,
    italicFallback: Bool
  ) -> Entry? {
    guard Self.useScalarFastPath else {
      return entry(
        character: Character(scalar),
        font: font,
        boldFallback: boldFallback,
        italicFallback: italicFallback)
    }
    let fid = ObjectIdentifier(font)
    let sk = ScalarKey(
      scalar: scalar.value, font: fid,
      boldFallback: boldFallback, italicFallback: italicFallback)
    if let cached = scalarEntries[sk] { return cached }
    let made = rasterizeAndPack(
      text: String(scalar), font: font,
      boldFallback: boldFallback, italicFallback: italicFallback)
    if let made { scalarEntries[sk] = made }
    return made
  }

  public func entry(
    character: Character,
    font: CTFont,
    boldFallback: Bool,
    italicFallback: Bool
  ) -> Entry? {
    let fid = ObjectIdentifier(font)
    // Fast path: single-scalar cluster (the common case). Integer-keyed lookup,
    // no per-glyph String allocation. Only the rare cache miss materialises a
    // String for rasterisation. Multi-scalar clusters (emoji/ZWJ/RI) fall back
    // to the String key so composed glyphs still resolve correctly.
    if Self.useScalarFastPath,
      character.unicodeScalars.count == 1,
      let scalar = character.unicodeScalars.first
    {
      let sk = ScalarKey(
        scalar: scalar.value, font: fid,
        boldFallback: boldFallback, italicFallback: italicFallback)
      if let cached = scalarEntries[sk] { return cached }
      let made = rasterizeAndPack(
        text: String(character), font: font,
        boldFallback: boldFallback, italicFallback: italicFallback)
      if let made { scalarEntries[sk] = made }
      return made
    }

    let text = String(character)
    let key = Key(
      text: text,
      font: fid,
      boldFallback: boldFallback,
      italicFallback: italicFallback)
    if let cached = entries[key] { return cached }
    let made = rasterizeAndPack(
      text: text, font: font,
      boldFallback: boldFallback, italicFallback: italicFallback)
    if let made {
      entries[key] = made
    }
    return made
  }

  func clearOverflowFlag() {
    didOverflow = false
  }

  // MARK: - Internal

  private func rasterizeAndPack(
    text: String,
    font: CTFont,
    boldFallback: Bool,
    italicFallback: Bool
  ) -> Entry? {
    guard !text.isEmpty else { return nil }
    let plan = rasterPlan(text: text, font: font)
    let layoutWidth = max(plan.layoutWidth, 0)
    let isWide = layoutWidth > cellWidth * 1.5
    let baseTileCellWidth = max(isWide ? cellWidth * 2 : cellWidth, layoutWidth)
    let inkBounds = normalizedInkBounds(plan.inkBounds, fallbackWidth: layoutWidth)

    let leftSlop = max(0, ceil(-inkBounds.minX))
    let rightInkSlop = max(0, ceil(inkBounds.maxX - baseTileCellWidth))
    let italicSlop: CGFloat = italicFallback ? ceil(cellHeight * abs(Self.italicShear)) : 0
    let boldSlop: CGFloat = boldFallback ? max(1.0 / scale, 0.5) : 0
    let rightSlop = rightInkSlop + italicSlop + boldSlop
    let logicalOriginX = -leftSlop
    let drawOriginX = leftSlop
    let logicalTileWidth = baseTileCellWidth + leftSlop + rightSlop
    let pixelW = max(1, Int((logicalTileWidth * scale).rounded(.up)))
    let pixelH = max(1, Int((cellHeight * scale).rounded(.up)))

    guard pixelW <= textureSize, pixelH <= textureSize else {
      didOverflow = true
      return nil
    }

    // Allocate from the shelf packer.
    if shelfX + pixelW > textureSize {
      // New shelf row.
      shelfX = 0
      shelfY += shelfHeight
      shelfHeight = 0
    }
    if shelfY + pixelH > textureSize {
      didOverflow = true
      return nil
    }
    let originX = shelfX
    let originY = shelfY
    shelfX += pixelW
    shelfHeight = max(shelfHeight, pixelH)

    // Rasterize alpha mask into a CPU buffer.
    let bytesPerRow = pixelW
    var pixelBytes = [UInt8](repeating: 0, count: bytesPerRow * pixelH)

    pixelBytes.withUnsafeMutableBytes { rawPtr in
      guard let baseAddr = rawPtr.baseAddress else { return }
      guard
        let ctx = CGContext(
          data: baseAddr,
          width: pixelW,
          height: pixelH,
          bitsPerComponent: 8,
          bytesPerRow: bytesPerRow,
          space: colorSpace,
          bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue
        )
      else { return }
      ctx.scaleBy(x: scale, y: scale)
      if italicFallback {
        ctx.concatenate(
          CGAffineTransform(a: 1, b: 0, c: Self.italicShear, d: 1, tx: 0, ty: 0))
      }
      ctx.setFillColor(CGColor(gray: 1, alpha: 1))
      ctx.textMatrix = .identity

      func drawPlan(xOffset: CGFloat) {
        switch plan {
        case .glyph(let glyph, _, _):
          let positions = [CGPoint(x: xOffset, y: descent)]
          glyph.withUnsafePointer { gPtr in
            positions.withUnsafeBufferPointer { pPtr in
              if let pBase = pPtr.baseAddress {
                CTFontDrawGlyphs(font, gPtr, pBase, 1, ctx)
              }
            }
          }

        case .line(let line, _, _):
          ctx.textMatrix = .identity
          ctx.textPosition = CGPoint(x: xOffset, y: descent)
          CTLineDraw(line, ctx)
        }
      }

      drawPlan(xOffset: drawOriginX)
      if boldFallback {
        drawPlan(xOffset: drawOriginX + max(1.0 / scale, 0.5))
      }
    }

    pixelBytes.withUnsafeBytes { ptr in
      if let base = ptr.baseAddress {
        texture.replace(
          region: MTLRegionMake2D(originX, originY, pixelW, pixelH),
          mipmapLevel: 0,
          withBytes: base,
          bytesPerRow: bytesPerRow)
      }
    }

    return Entry(
      pixelWidth: pixelW, pixelHeight: pixelH,
      originX: originX, originY: originY,
      logicalOriginX: logicalOriginX,
      logicalWidth: logicalTileWidth)
  }

  private func normalizedInkBounds(_ bounds: CGRect, fallbackWidth: CGFloat) -> CGRect {
    guard !bounds.isNull, !bounds.isInfinite else {
      return CGRect(x: 0, y: 0, width: max(fallbackWidth, 0), height: cellHeight)
    }
    let standardized = bounds.standardized
    guard standardized.width.isFinite, standardized.height.isFinite else {
      return CGRect(x: 0, y: 0, width: max(fallbackWidth, 0), height: cellHeight)
    }
    return standardized
  }

  private func rasterPlan(text: String, font: CTFont) -> RasterPlan {
    if let glyphPlan = simpleGlyphPlan(text: text, font: font) {
      return glyphPlan
    }
    let line = fallbackLine(text: text, font: font)
    var ascent: CGFloat = 0
    var descent: CGFloat = 0
    var leading: CGFloat = 0
    let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
    let glyphBounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
    return .line(line, width: max(width, 0), bounds: glyphBounds)
  }

  private func simpleGlyphPlan(text: String, font: CTFont) -> RasterPlan? {
    guard text.unicodeScalars.count == 1,
      let scalar = text.unicodeScalars.first,
      scalar.value <= UInt32(UInt16.max),
      let glyph = lookupGlyph(scalar: scalar, font: font)
    else { return nil }
    let advance = lookupAdvance(glyph: glyph, font: font)
    var glyphCopy = glyph
    let bounds = CTFontGetBoundingRectsForGlyphs(font, .default, &glyphCopy, nil, 1)
    return .glyph(glyph, advance: advance, bounds: bounds)
  }

  private func fallbackLine(text: String, font: CTFont) -> CTLine {
    let attrStr = NSMutableAttributedString(string: text)
    let range = NSRange(location: 0, length: attrStr.length)
    attrStr.addAttribute(
      kCTFontAttributeName as NSAttributedString.Key,
      value: font,
      range: range
    )
    attrStr.addAttribute(
      kCTForegroundColorAttributeName as NSAttributedString.Key,
      value: CGColor(gray: 1, alpha: 1),
      range: range
    )
    return CTLineCreateWithAttributedString(attrStr)
  }

  private func lookupGlyph(scalar: Unicode.Scalar, font: CTFont) -> CGGlyph? {
    guard scalar.value <= UInt32(UInt16.max) else { return nil }
    let fid = ObjectIdentifier(font)
    if let g = glyphForScalar[fid]?[scalar.value] {
      return g == 0 ? nil : g
    }
    var unit = UniChar(scalar.value)
    var g = CGGlyph()
    let ok = CTFontGetGlyphsForCharacters(font, &unit, &g, 1)
    glyphForScalar[fid, default: [:]][scalar.value] = ok ? g : 0
    return ok && g != 0 ? g : nil
  }

  private func lookupAdvance(glyph: CGGlyph, font: CTFont) -> CGFloat {
    let fid = ObjectIdentifier(font)
    if let a = advanceForGlyph[fid]?[glyph] { return a }
    var glyphCopy = glyph
    var advanceRect = CGSize.zero
    let value = CTFontGetAdvancesForGlyphs(font, .horizontal, &glyphCopy, &advanceRect, 1)
    advanceForGlyph[fid, default: [:]][glyph] = CGFloat(value)
    return CGFloat(value)
  }
}

extension CGGlyph {
  fileprivate func withUnsafePointer<R>(_ body: (UnsafePointer<CGGlyph>) -> R) -> R {
    var copy = self
    return Swift.withUnsafePointer(to: &copy) { body($0) }
  }
}
