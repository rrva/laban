import CoreGraphics
import CoreText
import Foundation
import Metal
import MetalKit

/// GPU glyph atlas: a single R8 MTLTexture holding antialiased alpha masks
/// for every (scalar, font, bold-fallback, italic-fallback) tuple seen so
/// far. Glyphs are packed with a simple shelf algorithm; the texture grows
/// only via fresh allocation on full (rare).
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
    /// Logical (CG-points) tile width; matches the per-cell drawing width
    /// so wide CJK glyphs occupy two cells and italic-shifted glyphs reserve
    /// the slop on the right.
    public let logicalWidth: CGFloat
  }

  private struct Key: Hashable {
    let scalar: UInt32
    let font: ObjectIdentifier
    let boldFallback: Bool
    let italicFallback: Bool
  }

  // Italic shear matches SoftwareRenderer's fake-italic transform.
  private static let italicShear: CGFloat = -0.18

  private let device: MTLDevice
  public let texture: MTLTexture
  public let textureSize: Int

  private let scale: CGFloat
  private let cellWidth: CGFloat
  private let cellHeight: CGFloat
  private let descent: CGFloat
  private let colorSpace = CGColorSpaceCreateDeviceGray()

  private var entries: [Key: Entry?] = [:]
  private var glyphForScalar: [ObjectIdentifier: [UInt32: CGGlyph]] = [:]
  private var advanceForGlyph: [ObjectIdentifier: [CGGlyph: CGFloat]] = [:]

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
    let key = Key(
      scalar: scalar.value,
      font: ObjectIdentifier(font),
      boldFallback: boldFallback,
      italicFallback: italicFallback)
    if let cached = entries[key] { return cached }
    let made = rasterizeAndPack(
      scalar: scalar, font: font,
      boldFallback: boldFallback, italicFallback: italicFallback)
    entries[key] = made
    return made
  }

  // MARK: - Internal

  private func rasterizeAndPack(
    scalar: Unicode.Scalar,
    font: CTFont,
    boldFallback: Bool,
    italicFallback: Bool
  ) -> Entry? {
    guard let glyph = lookupGlyph(scalar: scalar, font: font) else { return nil }
    let advance = lookupAdvance(glyph: glyph, font: font)
    let isWide = advance > cellWidth * 1.5
    let baseTileCellWidth = isWide ? cellWidth * 2 : cellWidth

    let italicSlop: CGFloat = italicFallback ? ceil(cellHeight * abs(Self.italicShear)) : 0
    let boldSlop: CGFloat = boldFallback ? max(1.0 / scale, 0.5) : 0
    let logicalTileWidth = baseTileCellWidth + italicSlop + boldSlop
    let pixelW = max(1, Int((logicalTileWidth * scale).rounded(.up)))
    let pixelH = max(1, Int((cellHeight * scale).rounded(.up)))

    // Allocate from the shelf packer.
    if shelfX + pixelW > textureSize {
      // New shelf row.
      shelfX = 0
      shelfY += shelfHeight
      shelfHeight = 0
    }
    if shelfY + pixelH > textureSize {
      // Out of room. Could grow the texture; for now drop the glyph.
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
      var glyphCopy = glyph
      var positions = [CGPoint(x: 0, y: descent)]
      glyphCopy.withUnsafePointer { gPtr in
        positions.withUnsafeBufferPointer { pPtr in
          if let pBase = pPtr.baseAddress {
            CTFontDrawGlyphs(font, gPtr, pBase, 1, ctx)
          }
        }
      }
      if boldFallback {
        var shifted = [CGPoint(x: max(1.0 / scale, 0.5), y: descent)]
        glyphCopy.withUnsafePointer { gPtr in
          shifted.withUnsafeBufferPointer { pPtr in
            if let pBase = pPtr.baseAddress {
              CTFontDrawGlyphs(font, gPtr, pBase, 1, ctx)
            }
          }
        }
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
      logicalWidth: logicalTileWidth)
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
