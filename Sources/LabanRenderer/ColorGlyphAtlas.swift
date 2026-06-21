import CoreGraphics
import CoreText
import Foundation
import Metal

/// BGRA atlas for CoreText color/bitmap glyphs such as Apple Color Emoji.
///
/// This atlas is deliberately separate from `MetalGlyphAtlas`: the existing R8
/// atlas remains the compatibility path for monochrome/tinted glyph rendering.
final class ColorGlyphAtlas {
  struct Entry {
    let pixelWidth: Int
    let pixelHeight: Int
    let originX: Int
    let originY: Int
    let logicalOriginX: CGFloat
    let logicalWidth: CGFloat
  }

  private struct Key: Hashable {
    let text: String
    let font: ObjectIdentifier
    let boldFallback: Bool
    let italicFallback: Bool
  }

  private let device: MTLDevice
  let texture: MTLTexture
  let textureSize: Int

  private let scale: CGFloat
  private let cellWidth: CGFloat
  private let cellHeight: CGFloat
  private let descent: CGFloat
  private let colorSpace = CGColorSpaceCreateDeviceRGB()
  private var entries: [Key: Entry] = [:]
  private(set) var didOverflow = false

  private var shelfX = 0
  private var shelfY = 0
  private var shelfHeight = 0

  init?(
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
    desc.pixelFormat = .bgra8Unorm
    desc.width = textureSize
    desc.height = textureSize
    desc.usage = [.shaderRead]
    desc.storageMode = .shared
    guard let tex = device.makeTexture(descriptor: desc) else { return nil }
    texture = tex

    let zeros = [UInt8](repeating: 0, count: textureSize * textureSize * 4)
    tex.replace(
      region: MTLRegionMake2D(0, 0, textureSize, textureSize),
      mipmapLevel: 0,
      withBytes: zeros,
      bytesPerRow: textureSize * 4)
  }

  func clearOverflowFlag() {
    didOverflow = false
  }

  func entry(
    character: Character,
    font: CTFont,
    boldFallback: Bool,
    italicFallback: Bool
  ) -> Entry? {
    entry(
      text: String(character),
      font: font,
      boldFallback: boldFallback,
      italicFallback: italicFallback)
  }

  func entry(
    text: String,
    font: CTFont,
    boldFallback: Bool,
    italicFallback: Bool
  ) -> Entry? {
    guard !text.isEmpty else { return nil }
    let key = Key(
      text: text,
      font: ObjectIdentifier(font),
      boldFallback: boldFallback,
      italicFallback: italicFallback)
    if let cached = entries[key] { return cached }
    guard
      ColorGlyphSupport.containsColorGlyph(
        text: text,
        font: font,
        cellAdvance: cellWidth)
    else { return nil }
    let made = rasterizeAndPack(text: text, font: font)
    if let made {
      entries[key] = made
    }
    return made
  }

  private func rasterizeAndPack(text: String, font: CTFont) -> Entry? {
    let line = TerminalGlyphFallback.fallbackLine(
      text: text,
      font: font,
      cellAdvance: cellWidth,
      foreground: nil)
    let layoutWidth = ColorGlyphSupport.typographicWidth(line)
    let logicalWidth = ColorGlyphSupport.logicalTileWidth(
      text: text,
      typographicWidth: layoutWidth,
      cellAdvance: cellWidth)
    let horizontalScale =
      layoutWidth > logicalWidth && layoutWidth > 0 ? logicalWidth / layoutWidth : 1
    let pixelW = max(1, Int((logicalWidth * scale).rounded(.up)))
    let pixelH = max(1, Int((cellHeight * scale).rounded(.up)))

    guard pixelW <= textureSize, pixelH <= textureSize else {
      didOverflow = true
      return nil
    }
    if shelfX + pixelW > textureSize {
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

    let bytesPerRow = pixelW * 4
    var pixelBytes = [UInt8](repeating: 0, count: bytesPerRow * pixelH)
    pixelBytes.withUnsafeMutableBytes { rawPtr in
      guard let baseAddr = rawPtr.baseAddress else { return }
      let bitmapInfo =
        CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
      guard
        let ctx = CGContext(
          data: baseAddr,
          width: pixelW,
          height: pixelH,
          bitsPerComponent: 8,
          bytesPerRow: bytesPerRow,
          space: colorSpace,
          bitmapInfo: bitmapInfo
        )
      else { return }
      ctx.scaleBy(x: scale, y: scale)
      ctx.textMatrix = .identity
      if horizontalScale < 1 {
        ctx.scaleBy(x: horizontalScale, y: 1)
      }
      ctx.textPosition = CGPoint(x: 0, y: descent)
      CTLineDraw(line, ctx)
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
      pixelWidth: pixelW,
      pixelHeight: pixelH,
      originX: originX,
      originY: originY,
      logicalOriginX: 0,
      logicalWidth: logicalWidth)
  }
}
