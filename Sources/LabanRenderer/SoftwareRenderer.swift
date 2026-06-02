import CoreGraphics
import CoreText
import Foundation

public final class SoftwareRenderer {
  public let surface: BitmapSurface
  public let fontAtlas: FontAtlas
  public let sidebarFontAtlas: FontAtlas
  private let glyphCellAdvance: CGFloat
  private let sidebarCellAdvance: CGFloat
  private var colorCache: [UInt32: CGColor] = [:]
  private var fontCache: [UInt32: CTFont] = [:]

  public init(
    surface: BitmapSurface,
    fontAtlas: FontAtlas,
    sidebarFontAtlas: FontAtlas? = nil
  ) {
    self.surface = surface
    self.fontAtlas = fontAtlas
    self.sidebarFontAtlas = sidebarFontAtlas ?? fontAtlas
    self.glyphCellAdvance = fontAtlas.cellSize.width
    self.sidebarCellAdvance = (sidebarFontAtlas ?? fontAtlas).cellSize.width
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

      case .glyphRun(
        let origin, let text, let fg, let bg, let attrs, let runSource,
        let underlineStyle, let underlineColor, _
      ):
        let atlas = runSource == .sidebar ? sidebarFontAtlas : fontAtlas
        let advance = runSource == .sidebar ? sidebarCellAdvance : glyphCellAdvance
        drawText(
          text, at: origin, foreground: fg, background: bg, attributes: attrs,
          underlineStyle: underlineStyle, underlineColor: underlineColor,
          atlas: atlas, cellAdvance: advance, in: ctx)

      case .cursor(let rect, let colorValue):
        ctx.setFillColor(color(colorValue))
        ctx.fill(rect)

      case .selection(let rect, let colorValue):
        ctx.setFillColor(color(colorValue))
        ctx.fill(rect)

      case .findMatch(let rect, let colorValue),
        .findSelected(let rect, let colorValue):
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
    underlineStyle: UnderlineStyle = .none,
    underlineColor: UInt32? = nil,
    atlas: FontAtlas,
    cellAdvance: CGFloat,
    in ctx: CGContext
  ) {
    let fgColor = color(fg)
    let font = styledFont(for: attributes, in: atlas)
    let traits = CTFontGetSymbolicTraits(font)
    let needsBoldFallback = attributes.contains(.bold) && !traits.contains(.traitBold)
    let needsItalicFallback = attributes.contains(.italic) && !traits.contains(.traitItalic)
    let baseline = origin.y + atlas.descent

    ctx.saveGState()
    if needsItalicFallback {
      ctx.translateBy(x: origin.x, y: origin.y)
      ctx.concatenate(CGAffineTransform(a: 1, b: 0, c: 0.18, d: 1, tx: 0, ty: 0))
      ctx.translateBy(x: -origin.x, y: -origin.y)
    }

    drawGlyphPass(
      text,
      origin: origin,
      baseline: baseline,
      xOffset: 0,
      font: font,
      foreground: fgColor,
      cellAdvance: cellAdvance,
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
        cellAdvance: cellAdvance,
        in: ctx
      )
    }
    ctx.restoreGState()

    let underlineColorCG = underlineColor.map { color($0) } ?? fgColor
    drawDecorations(
      for: text, at: origin, attributes: attributes,
      foreground: fgColor,
      underlineStyle: underlineStyle, underlineColor: underlineColorCG,
      atlas: atlas, cellAdvance: cellAdvance,
      in: ctx)
  }

  private func drawGlyphPass(
    _ text: String,
    origin: CGPoint,
    baseline: CGFloat,
    xOffset: CGFloat,
    font: CTFont,
    foreground fgColor: CGColor,
    cellAdvance: CGFloat,
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
        x: origin.x + CGFloat(cellIndex) * cellAdvance + xOffset,
        y: baseline
      )
      if let glyph = simpleGlyph(for: cluster, font: font) {
        glyphs.append(glyph)
        positions.append(cellOrigin)
      } else {
        flushGlyphs()
        drawFallbackText(
          String(cluster),
          at: cellOrigin,
          foreground: fgColor,
          font: font,
          cellAdvance: cellAdvance,
          in: ctx)
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
    cellAdvance: CGFloat,
    in ctx: CGContext
  ) {
    let line = TerminalGlyphFallback.fallbackLine(
      text: text,
      font: font,
      cellAdvance: cellAdvance,
      foreground: fgColor
    )
    ctx.textMatrix = .identity
    ctx.textPosition = position
    CTLineDraw(line, ctx)
  }

  private func styledFont(for attributes: TextAttributes, in atlas: FontAtlas) -> CTFont {
    let attrKey = UInt32(attributes.intersection([.bold, .italic]).rawValue)
    let atlasBit: UInt32 = (atlas === fontAtlas) ? 0 : 0x1_0000
    let key = attrKey | atlasBit
    if let cached = fontCache[key] { return cached }

    var desired: CTFontSymbolicTraits = []
    if attributes.contains(.bold) { desired.insert(.traitBold) }
    if attributes.contains(.italic) { desired.insert(.traitItalic) }

    let font =
      desired.isEmpty
      ? atlas.font
      : CTFontCreateCopyWithSymbolicTraits(
        atlas.font, atlas.pointSize, nil, desired, desired) ?? atlas.font
    fontCache[key] = font
    return font
  }

  private func drawDecorations(
    for text: String,
    at origin: CGPoint,
    attributes: TextAttributes,
    foreground fgColor: CGColor,
    underlineStyle: UnderlineStyle,
    underlineColor: CGColor,
    atlas: FontAtlas,
    cellAdvance: CGFloat,
    in ctx: CGContext
  ) {
    guard
      let layout = TextDecorationLayout.make(
        origin: origin,
        cellCount: text.count,
        attributes: attributes,
        underlineStyle: underlineStyle,
        cellAdvance: cellAdvance,
        cellHeight: atlas.cellSize.height,
        descent: atlas.descent,
        scale: surface.scale)
    else {
      return
    }

    ctx.saveGState()
    ctx.setFillColor(underlineColor)
    for rect in layout.underlineRects {
      ctx.fill(rect)
    }
    if !layout.curlyUnderlinePoints.isEmpty {
      ctx.setStrokeColor(underlineColor)
      ctx.setLineWidth(layout.thickness)
      ctx.setLineJoin(.round)
      ctx.beginPath()
      for (idx, point) in layout.curlyUnderlinePoints.enumerated() {
        if idx == 0 {
          ctx.move(to: point)
        } else {
          ctx.addLine(to: point)
        }
      }
      ctx.strokePath()
    }
    ctx.setFillColor(fgColor)
    if let rect = layout.strikethroughRect {
      ctx.fill(rect)
    }
    if let rect = layout.overlineRect {
      ctx.fill(rect)
    }
    ctx.restoreGState()
  }
}
