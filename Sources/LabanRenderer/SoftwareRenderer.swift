import CoreGraphics
import CoreText
import Foundation

public final class SoftwareRenderer {
  public let surface: BitmapSurface
  public let fontAtlas: FontAtlas
  private let glyphCellAdvance: CGFloat
  private var colorCache: [UInt32: CGColor] = [:]
  private var fontCache: [UInt16: CTFont] = [:]

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

      case .glyphRun(let origin, let text, let fg, let bg, let attrs, _):
        drawText(text, at: origin, foreground: fg, background: bg, attributes: attrs, in: ctx)

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
    _ text: String,
    at origin: CGPoint,
    foreground fg: UInt32,
    background _: UInt32,
    attributes: TextAttributes,
    in ctx: CGContext
  ) {
    let fgColor = color(fg)
    let font = styledFont(for: attributes)
    let traits = CTFontGetSymbolicTraits(font)
    let needsBoldFallback = attributes.contains(.bold) && !traits.contains(.traitBold)
    let needsItalicFallback = attributes.contains(.italic) && !traits.contains(.traitItalic)
    let baseline = origin.y + fontAtlas.descent

    ctx.saveGState()
    if needsItalicFallback {
      ctx.translateBy(x: origin.x, y: origin.y)
      ctx.concatenate(CGAffineTransform(a: 1, b: 0, c: -0.18, d: 1, tx: 0, ty: 0))
      ctx.translateBy(x: -origin.x, y: -origin.y)
    }

    drawGlyphPass(
      text,
      origin: origin,
      baseline: baseline,
      xOffset: 0,
      font: font,
      foreground: fgColor,
      in: ctx
    )
    if needsBoldFallback {
      drawGlyphPass(
        text,
        origin: origin,
        baseline: baseline,
        xOffset: max(1.0 / surface.scale, 0.5),
        font: font,
        foreground: fgColor,
        in: ctx
      )
    }
    ctx.restoreGState()

    drawDecorations(for: text, at: origin, attributes: attributes, foreground: fgColor, in: ctx)
  }

  private func drawGlyphPass(
    _ text: String,
    origin: CGPoint,
    baseline: CGFloat,
    xOffset: CGFloat,
    font: CTFont,
    foreground fgColor: CGColor,
    in ctx: CGContext
  ) {
    var glyphs: [CGGlyph] = []
    var positions: [CGPoint] = []

    ctx.textMatrix = .identity
    ctx.setFillColor(fgColor)

    func flushGlyphs() {
      guard !glyphs.isEmpty else { return }
      // CTLineDraw on a fallback line can leave the context's text matrix
      // non-identity. Reset before every CTFontDrawGlyphs batch so absolute
      // terminal-cell positions do not drift.
      ctx.textMatrix = .identity
      glyphs.withUnsafeBufferPointer { glyphBuffer in
        positions.withUnsafeBufferPointer { positionBuffer in
          guard let glyphBase = glyphBuffer.baseAddress,
            let positionBase = positionBuffer.baseAddress
          else { return }
          CTFontDrawGlyphs(font, glyphBase, positionBase, glyphs.count, ctx)
        }
      }
      glyphs.removeAll(keepingCapacity: true)
      positions.removeAll(keepingCapacity: true)
    }

    for (cellIndex, cluster) in text.enumerated() {
      let cellOrigin = CGPoint(
        x: origin.x + CGFloat(cellIndex) * glyphCellAdvance + xOffset,
        y: baseline
      )
      if let glyph = simpleGlyph(for: cluster, font: font) {
        glyphs.append(glyph)
        positions.append(cellOrigin)
      } else {
        flushGlyphs()
        drawFallbackText(String(cluster), at: cellOrigin, foreground: fgColor, font: font, in: ctx)
      }
    }
    flushGlyphs()
  }

  private func simpleGlyph(for character: Character, font: CTFont) -> CGGlyph? {
    guard character.unicodeScalars.count == 1,
      let scalar = character.unicodeScalars.first,
      scalar.value <= UInt32(UInt16.max)
    else { return nil }

    var codeUnit = UniChar(scalar.value)
    var glyph = CGGlyph()
    guard CTFontGetGlyphsForCharacters(font, &codeUnit, &glyph, 1), glyph != 0 else {
      return nil
    }
    return glyph
  }

  private func drawFallbackText(
    _ text: String,
    at position: CGPoint,
    foreground fgColor: CGColor,
    font: CTFont,
    in ctx: CGContext
  ) {
    let attrStr = NSMutableAttributedString(string: text)
    let range = NSRange(location: 0, length: attrStr.length)
    attrStr.addAttribute(
      kCTFontAttributeName as NSAttributedString.Key,
      value: font,
      range: range
    )
    attrStr.addAttribute(
      kCTForegroundColorAttributeName as NSAttributedString.Key,
      value: fgColor,
      range: range
    )
    let line = CTLineCreateWithAttributedString(attrStr)
    ctx.textMatrix = .identity
    ctx.textPosition = position
    CTLineDraw(line, ctx)
  }

  private func styledFont(for attributes: TextAttributes) -> CTFont {
    let key = attributes.intersection([.bold, .italic]).rawValue
    if let cached = fontCache[key] { return cached }

    var desired: CTFontSymbolicTraits = []
    if attributes.contains(.bold) { desired.insert(.traitBold) }
    if attributes.contains(.italic) { desired.insert(.traitItalic) }

    let font =
      desired.isEmpty
      ? fontAtlas.font
      : CTFontCreateCopyWithSymbolicTraits(
        fontAtlas.font, fontAtlas.pointSize, nil, desired, desired) ?? fontAtlas.font
    fontCache[key] = font
    return font
  }

  private func drawDecorations(
    for text: String,
    at origin: CGPoint,
    attributes: TextAttributes,
    foreground fgColor: CGColor,
    in ctx: CGContext
  ) {
    guard !attributes.intersection([.underline, .strikethrough, .overline]).isEmpty,
      !text.isEmpty
    else {
      return
    }

    let width = CGFloat(text.count) * glyphCellAdvance
    let cellHeight = fontAtlas.cellSize.height
    let thickness = max(1.0 / surface.scale, 1)

    ctx.saveGState()
    ctx.setFillColor(fgColor)
    if attributes.contains(.underline) {
      ctx.fill(
        CGRect(
          x: origin.x,
          y: origin.y + max(1, floor(fontAtlas.descent * 0.45)),
          width: width,
          height: thickness
        ))
    }
    if attributes.contains(.strikethrough) {
      ctx.fill(
        CGRect(
          x: origin.x,
          y: origin.y + floor(cellHeight * 0.52),
          width: width,
          height: thickness
        ))
    }
    if attributes.contains(.overline) {
      ctx.fill(
        CGRect(
          x: origin.x,
          y: origin.y + cellHeight - thickness - 1,
          width: width,
          height: thickness
        ))
    }
    ctx.restoreGState()
  }
}
