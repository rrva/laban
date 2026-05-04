import CoreGraphics
import Foundation

// Procedural geometry for Block Elements (U+2580–U+259F).
//
// When rendered as font glyphs, block elements leave hairline gaps at the
// cell boundary because the font's glyph metrics don't exactly fill the
// terminal cell. Producing integer-aligned filled rectangles instead
// guarantees gap-free tiling regardless of the loaded font, and keeps the
// renderer abstraction backend-agnostic — software, Metal, or any other
// future backend just sees `.rect` FrameCommands.
//
// Geometry uses CoreGraphics conventions: (origin.x, origin.y) is the
// cell's bottom-left corner; the cell spans up to (origin.x+w, origin.y+h).
public enum BoxDrawing {

  public struct FilledRect {
    public let rect: CGRect
    public let color: UInt32
  }

  public static func isBlockElement(_ scalar: Unicode.Scalar) -> Bool {
    return (0x2580...0x259F).contains(scalar.value)
  }

  public static func isGeometricTriangle(_ scalar: Unicode.Scalar) -> Bool {
    return (0x25E2...0x25E5).contains(scalar.value)
  }

  public static func isProceduralCellElement(_ scalar: Unicode.Scalar) -> Bool {
    isBlockElement(scalar) || isGeometricTriangle(scalar)
  }

  public static func proceduralCellElementRects(
    _ scalar: Unicode.Scalar,
    at origin: CGPoint,
    cellWidth w: CGFloat,
    cellHeight h: CGFloat,
    foreground: UInt32
  ) -> [FilledRect] {
    if isBlockElement(scalar) {
      return blockElementRects(
        scalar, at: origin, cellWidth: w, cellHeight: h, foreground: foreground)
    }
    if isGeometricTriangle(scalar) {
      return triangleRects(scalar, at: origin, cellWidth: w, cellHeight: h, foreground: foreground)
    }
    return []
  }

  // Returns the filled-rectangle decomposition of `scalar` placed at the
  // given cell origin. Returns an empty array if the scalar is not a Block
  // Element (caller should gate on isBlockElement first).
  //
  // For shading characters (░▒▓) the returned rect carries an alpha-reduced
  // form of `foreground` so the rect alpha-blends over whatever has already
  // been drawn in the cell.
  public static func blockElementRects(
    _ scalar: Unicode.Scalar,
    at origin: CGPoint,
    cellWidth w: CGFloat,
    cellHeight h: CGFloat,
    foreground: UInt32
  ) -> [FilledRect] {
    let x = origin.x
    let y = origin.y

    // Halve at the floor so adjacent halves share an integer pixel boundary;
    // the complement absorbs the rounding remainder so the two halves
    // together exactly cover the cell (critical for odd cell dimensions).
    let leftW = floor(w / 2)
    let rightW = w - leftW
    let bottomH = floor(h / 2)
    let topH = h - bottomH

    let topLeft = CGRect(x: x, y: y + bottomH, width: leftW, height: topH)
    let topRight = CGRect(x: x + leftW, y: y + bottomH, width: rightW, height: topH)
    let botLeft = CGRect(x: x, y: y, width: leftW, height: bottomH)
    let botRight = CGRect(x: x + leftW, y: y, width: rightW, height: bottomH)

    func one(_ r: CGRect) -> [FilledRect] { [FilledRect(rect: r, color: foreground)] }

    switch scalar.value {
    // ▀ U+2580 UPPER HALF BLOCK
    case 0x2580:
      return one(CGRect(x: x, y: y + bottomH, width: w, height: topH))

    // ▁..▇ U+2581..U+2587 LOWER N/8 BLOCK (N = 1..7)
    case 0x2581...0x2587:
      let n = CGFloat(scalar.value - 0x2580)
      let bh = (h * n / 8).rounded()
      return one(CGRect(x: x, y: y, width: w, height: bh))

    // █ U+2588 FULL BLOCK
    case 0x2588:
      return one(CGRect(x: x, y: y, width: w, height: h))

    // ▉..▏ U+2589..U+258F LEFT N/8 BLOCK (N = 7..1)
    case 0x2589...0x258F:
      let n = CGFloat(0x2590 - scalar.value)
      let bw = (w * n / 8).rounded()
      return one(CGRect(x: x, y: y, width: bw, height: h))

    // ▐ U+2590 RIGHT HALF BLOCK
    case 0x2590:
      return one(CGRect(x: x + leftW, y: y, width: rightW, height: h))

    // ░ ▒ ▓ U+2591..U+2593 SHADING (light/medium/dark)
    case 0x2591...0x2593:
      let alphaSteps: [UInt32] = [0x40, 0x80, 0xC0]
      let alpha = alphaSteps[Int(scalar.value - 0x2591)]
      let shaded = (foreground & 0xFFFF_FF00) | alpha
      return [
        FilledRect(rect: CGRect(x: x, y: y, width: w, height: h), color: shaded)
      ]

    // ▔ U+2594 UPPER ONE EIGHTH BLOCK
    case 0x2594:
      let bh = (h / 8).rounded()
      return one(CGRect(x: x, y: y + h - bh, width: w, height: bh))

    // ▕ U+2595 RIGHT ONE EIGHTH BLOCK
    case 0x2595:
      let bw = (w / 8).rounded()
      return one(CGRect(x: x + w - bw, y: y, width: bw, height: h))

    // ▖ U+2596 QUADRANT LOWER LEFT
    case 0x2596: return one(botLeft)
    // ▗ U+2597 QUADRANT LOWER RIGHT
    case 0x2597: return one(botRight)
    // ▘ U+2598 QUADRANT UPPER LEFT
    case 0x2598: return one(topLeft)
    // ▙ U+2599 UPPER LEFT + LOWER LEFT + LOWER RIGHT
    case 0x2599:
      return [
        FilledRect(rect: topLeft, color: foreground),
        FilledRect(rect: botLeft, color: foreground),
        FilledRect(rect: botRight, color: foreground),
      ]
    // ▚ U+259A UPPER LEFT + LOWER RIGHT
    case 0x259A:
      return [
        FilledRect(rect: topLeft, color: foreground),
        FilledRect(rect: botRight, color: foreground),
      ]
    // ▛ U+259B UPPER LEFT + UPPER RIGHT + LOWER LEFT
    case 0x259B:
      return [
        FilledRect(rect: topLeft, color: foreground),
        FilledRect(rect: topRight, color: foreground),
        FilledRect(rect: botLeft, color: foreground),
      ]
    // ▜ U+259C UPPER LEFT + UPPER RIGHT + LOWER RIGHT
    case 0x259C:
      return [
        FilledRect(rect: topLeft, color: foreground),
        FilledRect(rect: topRight, color: foreground),
        FilledRect(rect: botRight, color: foreground),
      ]
    // ▝ U+259D QUADRANT UPPER RIGHT
    case 0x259D: return one(topRight)
    // ▞ U+259E UPPER RIGHT + LOWER LEFT
    case 0x259E:
      return [
        FilledRect(rect: topRight, color: foreground),
        FilledRect(rect: botLeft, color: foreground),
      ]
    // ▟ U+259F UPPER RIGHT + LOWER LEFT + LOWER RIGHT
    case 0x259F:
      return [
        FilledRect(rect: topRight, color: foreground),
        FilledRect(rect: botLeft, color: foreground),
        FilledRect(rect: botRight, color: foreground),
      ]

    default:
      return []
    }
  }

  private static func triangleRects(
    _ scalar: Unicode.Scalar,
    at origin: CGPoint,
    cellWidth w: CGFloat,
    cellHeight h: CGFloat,
    foreground: UInt32
  ) -> [FilledRect] {
    let stripCount = max(1, Int(ceil(h)))
    var rects: [FilledRect] = []
    rects.reserveCapacity(stripCount)

    for strip in 0..<stripCount {
      let y = origin.y + CGFloat(strip)
      let height = min(1, origin.y + h - y)
      guard height > 0 else { continue }

      let bottomToTop = CGFloat(strip + 1) / CGFloat(stripCount)
      let topToBottom = CGFloat(stripCount - strip) / CGFloat(stripCount)
      let fraction: CGFloat
      let alignRight: Bool

      switch scalar.value {
      case 0x25E2:  // ◢ BLACK LOWER RIGHT TRIANGLE
        fraction = topToBottom
        alignRight = true
      case 0x25E3:  // ◣ BLACK LOWER LEFT TRIANGLE
        fraction = topToBottom
        alignRight = false
      case 0x25E4:  // ◤ BLACK UPPER LEFT TRIANGLE
        fraction = bottomToTop
        alignRight = false
      case 0x25E5:  // ◥ BLACK UPPER RIGHT TRIANGLE
        fraction = bottomToTop
        alignRight = true
      default:
        return []
      }

      let width = max(1, min(w, (w * fraction).rounded(.up)))
      let x = alignRight ? origin.x + w - width : origin.x
      rects.append(
        FilledRect(
          rect: CGRect(x: x, y: y, width: width, height: height),
          color: foreground
        ))
    }

    return rects
  }
}
