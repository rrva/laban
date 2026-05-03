import CoreGraphics
import CoreText
import Foundation

public final class SoftwareRenderer {
  public let surface: BitmapSurface
  public let fontAtlas: FontAtlas
  private var colorCache: [UInt32: CGColor] = [:]

  public init(surface: BitmapSurface, fontAtlas: FontAtlas) {
    self.surface = surface
    self.fontAtlas = fontAtlas
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

    // Baseline sits above the cell's bottom edge by |descent|.
    let baseline = origin.y + fontAtlas.descent

    ctx.saveGState()
    ctx.textMatrix = .identity
    ctx.textPosition = CGPoint(x: origin.x, y: baseline)
    CTLineDraw(line, ctx)
    ctx.restoreGState()
  }
}
