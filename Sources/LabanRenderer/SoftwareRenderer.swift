import CoreGraphics
import CoreText
import Foundation

public final class SoftwareRenderer {
  public let surface: BitmapSurface
  public let fontAtlas: FontAtlas
  private let glyphCellAdvance: CGFloat
  private var colorCache: [UInt32: CGColor] = [:]

  public init(surface: BitmapSurface, fontAtlas: FontAtlas) {
    self.surface = surface
    self.fontAtlas = fontAtlas
    self.glyphCellAdvance = fontAtlas.cellSize.width
  }

  private func color(_ rgba: UInt32) -> CGColor {
    if let cached = colorCache[rgba] { return cached }
    let c = cgColorFrom(rgba)
    colorCache[rgba] = c
    return c
  }

  public func render(_ commands: [FrameCommand]) {
    let ctx = surface.context
    ctx.saveGState()
    ctx.scaleBy(x: surface.scale, y: surface.scale)
    for cmd in commands {
      switch cmd {
      case .rect(let rect, let colorValue, _):
        ctx.setFillColor(color(colorValue))
        ctx.fill(rect)

      case .glyphRun(let origin, let text, let fg, _, _):
        drawText(text, at: origin, foreground: fg, in: ctx)

      case .cursor(let rect, let colorValue):
        ctx.setFillColor(color(colorValue))
        ctx.fill(rect)

      case .selection(let rect, let colorValue):
        ctx.setFillColor(color(colorValue))
        ctx.fill(rect)

      case .clip(let rect):
        ctx.clip(to: rect)

      case .texturedQuad:
        // Kitty graphics / image quads are deferred; command is accepted
        // but not drawn by the software renderer in this shard.
        break
      }
    }
    ctx.restoreGState()
  }

  private func drawText(
    _ text: String, at origin: CGPoint, foreground fg: UInt32, in ctx: CGContext
  ) {
    let fgColor = color(fg)
    let baseline = origin.y + fontAtlas.descent

    var glyphs: [CGGlyph] = []
    var positions: [CGPoint] = []

    ctx.saveGState()
    ctx.textMatrix = .identity
    ctx.setFillColor(fgColor)

    func flushGlyphs() {
      guard !glyphs.isEmpty else { return }
      // CTLineDraw on a fallback line — used for symbols like U+23F5 that
      // JetBrains Mono lacks — leaves the context's text matrix non-identity.
      // CTFontDrawGlyphs transforms the positions array by that matrix, so
      // the absolute pen position drifts unless we reset before each batch.
      // saveGState does not save text matrix per Apple's docs, so the reset
      // has to be explicit here.
      ctx.textMatrix = .identity
      glyphs.withUnsafeBufferPointer { glyphBuffer in
        positions.withUnsafeBufferPointer { positionBuffer in
          guard let glyphBase = glyphBuffer.baseAddress,
            let positionBase = positionBuffer.baseAddress
          else { return }
          CTFontDrawGlyphs(fontAtlas.font, glyphBase, positionBase, glyphs.count, ctx)
        }
      }
      glyphs.removeAll(keepingCapacity: true)
      positions.removeAll(keepingCapacity: true)
    }

    for (cellIndex, cluster) in text.enumerated() {
      let cellOrigin = CGPoint(
        x: origin.x + CGFloat(cellIndex) * glyphCellAdvance,
        y: baseline
      )
      if let glyph = simpleGlyph(for: cluster) {
        glyphs.append(glyph)
        positions.append(cellOrigin)
      } else {
        flushGlyphs()
        drawFallbackText(String(cluster), at: cellOrigin, foreground: fgColor, in: ctx)
      }
    }

    flushGlyphs()
    ctx.restoreGState()
  }

  private func simpleGlyph(for character: Character) -> CGGlyph? {
    guard character.unicodeScalars.count == 1,
      let scalar = character.unicodeScalars.first,
      scalar.value <= UInt32(UInt16.max)
    else { return nil }

    var codeUnit = UniChar(scalar.value)
    var glyph = CGGlyph()
    guard CTFontGetGlyphsForCharacters(fontAtlas.font, &codeUnit, &glyph, 1), glyph != 0 else {
      return nil
    }
    return glyph
  }

  private func drawFallbackText(
    _ text: String, at position: CGPoint, foreground fgColor: CGColor, in ctx: CGContext
  ) {
    let attrStr = NSMutableAttributedString(string: text)
    let range = NSRange(location: 0, length: attrStr.length)
    attrStr.addAttribute(
      kCTFontAttributeName as NSAttributedString.Key,
      value: fontAtlas.font,
      range: range
    )
    attrStr.addAttribute(
      kCTForegroundColorAttributeName as NSAttributedString.Key,
      value: fgColor,
      range: range
    )
    let line = CTLineCreateWithAttributedString(attrStr)
    ctx.textPosition = position
    CTLineDraw(line, ctx)
  }
}
