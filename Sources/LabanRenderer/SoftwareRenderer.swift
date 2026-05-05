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
    let drawsUnderline = attributes.contains(.underline) || underlineStyle != .none
    guard
      drawsUnderline || attributes.contains(.strikethrough) || attributes.contains(.overline),
      !text.isEmpty
    else {
      return
    }

    let width = CGFloat(text.count) * cellAdvance
    let cellHeight = atlas.cellSize.height
    let thickness = max(1.0 / surface.scale, 1)

    ctx.saveGState()
    if drawsUnderline {
      // The cell's underline_style takes precedence; .underline alone is
      // single. .none here means the attribute flag is set without a sub-style.
      let style: UnderlineStyle = underlineStyle == .none ? .single : underlineStyle
      let underlineY = origin.y + max(1, floor(atlas.descent * 0.45))
      drawUnderline(
        style: style,
        x: origin.x,
        y: underlineY,
        width: width,
        thickness: thickness,
        cellAdvance: cellAdvance,
        color: underlineColor,
        in: ctx)
    }
    ctx.setFillColor(fgColor)
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

  private func drawUnderline(
    style: UnderlineStyle,
    x: CGFloat,
    y: CGFloat,
    width: CGFloat,
    thickness: CGFloat,
    cellAdvance: CGFloat,
    color: CGColor,
    in ctx: CGContext
  ) {
    ctx.setFillColor(color)
    ctx.setStrokeColor(color)
    switch style {
    case .none:
      return
    case .single:
      ctx.fill(CGRect(x: x, y: y, width: width, height: thickness))
    case .double:
      // Two thin lines, one at the underline position and one slightly above.
      ctx.fill(CGRect(x: x, y: y, width: width, height: thickness))
      let gap = max(thickness, 1)
      ctx.fill(CGRect(x: x, y: y + thickness + gap, width: width, height: thickness))
    case .curly:
      // Sine wave approximated with line segments at one cell-width period.
      let amplitude = max(thickness * 1.2, 1.0)
      let period = max(cellAdvance, 6)
      let baseY = y + thickness * 0.5
      ctx.setLineWidth(thickness)
      ctx.setLineJoin(.round)
      ctx.beginPath()
      let steps = max(Int(width / 1.5), 8)
      for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps)
        let cx = x + width * t
        let cy = baseY + amplitude * CGFloat(sin((Double(t) * Double(width) / Double(period)) * 2 * .pi))
        if i == 0 { ctx.move(to: CGPoint(x: cx, y: cy)) }
        else { ctx.addLine(to: CGPoint(x: cx, y: cy)) }
      }
      ctx.strokePath()
    case .dotted:
      let dot = max(thickness, 1)
      var cx = x
      while cx < x + width {
        ctx.fill(CGRect(x: cx, y: y, width: dot, height: thickness))
        cx += dot * 2
      }
    case .dashed:
      let dash = max(cellAdvance * 0.5, 3)
      let gap = max(cellAdvance * 0.25, 2)
      var cx = x
      while cx < x + width {
        let segW = min(dash, x + width - cx)
        ctx.fill(CGRect(x: cx, y: y, width: segW, height: thickness))
        cx += dash + gap
      }
    }
  }
}
