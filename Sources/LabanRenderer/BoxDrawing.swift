import CoreGraphics
import Foundation

// Procedural geometry for Block Elements (U+2580–U+259F), straight Box Drawing
// lines (U+2500–U+257F), Braille (U+2800–U+28FF) and sextants (U+1FB00–U+1FB3B).
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
    isBlockElement(scalar) || isGeometricTriangle(scalar) || isBoxLine(scalar)
      || isBraille(scalar) || isSextant(scalar)
  }

  /// Straight light/heavy Box Drawing lines, including dashed and half lines.
  /// Double lines, arcs and diagonals keep the font outline.
  public static func isBoxLine(_ scalar: Unicode.Scalar) -> Bool {
    boxLineSpec(scalar) != nil
  }

  public static func isBraille(_ scalar: Unicode.Scalar) -> Bool {
    (0x2800...0x28FF).contains(scalar.value)
  }

  /// Symbols for Legacy Computing sextants (U+1FB00–U+1FB3B).
  public static func isSextant(_ scalar: Unicode.Scalar) -> Bool {
    (0x1FB00...0x1FB3B).contains(scalar.value)
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
    if let spec = boxLineSpec(scalar) {
      return boxLineRects(spec, at: origin, cellWidth: w, cellHeight: h, foreground: foreground)
    }
    if isBraille(scalar) {
      return brailleRects(scalar, at: origin, cellWidth: w, cellHeight: h, foreground: foreground)
    }
    if isSextant(scalar) {
      return sextantRects(scalar, at: origin, cellWidth: w, cellHeight: h, foreground: foreground)
    }
    return []
  }

  // MARK: - Box Drawing lines (U+2500–U+257F)

  /// Arm weights (0 none, 1 light, 2 heavy) toward up/right/down/left, plus
  /// the dash count for dashed lines (0 = solid).
  struct BoxLineSpec: Equatable {
    var up: Int
    var right: Int
    var down: Int
    var left: Int
    var dashes: Int
  }

  /// "urdl" arm weights for U+2500–U+254F; nil marks double/mixed lines.
  private static let boxLineArms: [String?] = [
    "0101", "0202", "1010", "2020", "0101", "0202", "1010", "2020",  // 2500-2507
    "0101", "0202", "1010", "2020", "0110", "0210", "0120", "0220",  // 2508-250F
    "0011", "0012", "0021", "0022", "1100", "1200", "2100", "2200",  // 2510-2517
    "1001", "1002", "2001", "2002", "1110", "1210", "2110", "1120",  // 2518-251F
    "2120", "2210", "1220", "2220", "1011", "1012", "2011", "1021",  // 2520-2527
    "2021", "2012", "1022", "2022", "0111", "0112", "0211", "0212",  // 2528-252F
    "0121", "0122", "0221", "0222", "1101", "1102", "1201", "1202",  // 2530-2537
    "2101", "2102", "2201", "2202", "1111", "1112", "1211", "1212",  // 2538-253F
    "2111", "1121", "2121", "2112", "2211", "1122", "1221", "2212",  // 2540-2547
    "1222", "2122", "2221", "2222", "0101", "0202", "1010", "2020",  // 2548-254F
  ]

  /// Half lines and light/heavy mixes, U+2574–U+257F.
  private static let boxHalfLineArms: [String] = [
    "0001", "1000", "0100", "0010", "0002", "2000", "0200", "0020",
    "0201", "1020", "0102", "2010",
  ]

  /// Parsed once: index `value - 0x2500` for U+2500–U+257F.
  private static let boxLineSpecs: [BoxLineSpec?] = (0x2500...0x257F).map {
    parseBoxLineSpec(Unicode.Scalar($0)!)
  }

  static func boxLineSpec(_ scalar: Unicode.Scalar) -> BoxLineSpec? {
    guard (0x2500...0x257F).contains(scalar.value) else { return nil }
    return boxLineSpecs[Int(scalar.value - 0x2500)]
  }

  private static func parseBoxLineSpec(_ scalar: Unicode.Scalar) -> BoxLineSpec? {
    let value = scalar.value
    let arms: String
    var dashes = 0
    switch value {
    case 0x2500...0x254F:
      guard let entry = boxLineArms[Int(value - 0x2500)] else { return nil }
      arms = entry
      switch value {
      case 0x2504...0x2507: dashes = 3
      case 0x2508...0x250B: dashes = 4
      case 0x254C...0x254F: dashes = 2
      default: break
      }
    case 0x2574...0x257F:
      arms = boxHalfLineArms[Int(value - 0x2574)]
    default:
      return nil
    }
    let weights = arms.compactMap { $0.wholeNumberValue }
    return BoxLineSpec(
      up: weights[0], right: weights[1], down: weights[2], left: weights[3], dashes: dashes)
  }

  /// Light stroke thickness in points for a cell; heavy is twice that.
  /// Whole points keep strokes on device-pixel boundaries at integer scales.
  static func lightStroke(cellWidth w: CGFloat) -> CGFloat {
    max(1, (w / 8).rounded())
  }

  private static func boxLineRects(
    _ spec: BoxLineSpec,
    at origin: CGPoint,
    cellWidth w: CGFloat,
    cellHeight h: CGFloat,
    foreground: UInt32
  ) -> [FilledRect] {
    let light = lightStroke(cellWidth: w)
    func thickness(_ weight: Int) -> CGFloat { weight >= 2 ? light * 2 : light }
    // Band start along an axis of `length` for a stroke of `weight`; centred
    // with floor so the same weight lands on the same pixels in every cell.
    func band(_ weight: Int, length: CGFloat) -> (start: CGFloat, end: CGFloat) {
      let t = thickness(weight)
      let start = ((length - t) / 2).rounded(.down)
      return (start, start + t)
    }
    let vertical = band(max(spec.up, spec.down, 1), length: w)
    let horizontal = band(max(spec.left, spec.right, 1), length: h)
    var rects: [CGRect] = []
    if spec.up > 0 {
      let b = band(spec.up, length: w)
      rects.append(
        CGRect(
          x: b.start, y: horizontal.start, width: b.end - b.start, height: h - horizontal.start))
    }
    if spec.down > 0 {
      let b = band(spec.down, length: w)
      rects.append(CGRect(x: b.start, y: 0, width: b.end - b.start, height: horizontal.end))
    }
    if spec.left > 0 {
      let b = band(spec.left, length: h)
      rects.append(CGRect(x: 0, y: b.start, width: vertical.end, height: b.end - b.start))
    }
    if spec.right > 0 {
      let b = band(spec.right, length: h)
      rects.append(
        CGRect(x: vertical.start, y: b.start, width: w - vertical.start, height: b.end - b.start))
    }
    if spec.dashes > 0 {
      rects = rects.flatMap { dashed($0, count: spec.dashes, horizontal: spec.left > 0) }
    }
    return rects.map {
      FilledRect(rect: $0.offsetBy(dx: origin.x, dy: origin.y), color: foreground)
    }
  }

  /// Splits a full-cell stroke into `count` dashes. Each dash is centred in
  /// its slot so the gaps at the cell edges add up to one full gap between
  /// adjacent cells.
  private static func dashed(_ rect: CGRect, count: Int, horizontal: Bool) -> [CGRect] {
    let length = horizontal ? rect.width : rect.height
    let slot = length / CGFloat(count)
    let gap = max(1, (slot / 3).rounded())
    return (0..<count).map { index in
      let start = (CGFloat(index) * slot + gap / 2).rounded(.down)
      let end = (CGFloat(index + 1) * slot - gap / 2).rounded(.down)
      return horizontal
        ? CGRect(x: rect.minX + start, y: rect.minY, width: end - start, height: rect.height)
        : CGRect(x: rect.minX, y: rect.minY + start, width: rect.width, height: end - start)
    }
  }

  // MARK: - Braille (U+2800–U+28FF)

  private static func brailleRects(
    _ scalar: Unicode.Scalar,
    at origin: CGPoint,
    cellWidth w: CGFloat,
    cellHeight h: CGFloat,
    foreground: UInt32
  ) -> [FilledRect] {
    let pattern = scalar.value - 0x2800
    // Dot bits 1-8 → (column, row from top), per the Unicode braille layout.
    let dots: [(column: Int, row: Int)] = [
      (0, 0), (0, 1), (0, 2), (1, 0), (1, 1), (1, 2), (0, 3), (1, 3),
    ]
    let size = max(1, (min(w / 2, h / 4) * 0.55).rounded())
    var rects: [FilledRect] = []
    for (bit, dot) in dots.enumerated() where pattern & (1 << UInt32(bit)) != 0 {
      let centerX = w * CGFloat(2 * dot.column + 1) / 4
      let centerY = h - h * CGFloat(2 * dot.row + 1) / 8
      let rect = CGRect(
        x: origin.x + (centerX - size / 2).rounded(),
        y: origin.y + (centerY - size / 2).rounded(),
        width: size,
        height: size)
      rects.append(FilledRect(rect: rect, color: foreground))
    }
    return rects
  }

  // MARK: - Sextants (U+1FB00–U+1FB3B)

  private static func sextantRects(
    _ scalar: Unicode.Scalar,
    at origin: CGPoint,
    cellWidth w: CGFloat,
    cellHeight h: CGFloat,
    foreground: UInt32
  ) -> [FilledRect] {
    // Patterns 1...62 in order, skipping 21 (left column) and 42 (right
    // column), which are U+258C/U+2590. Bit n is sextant n+1: 1 top-left,
    // 2 top-right, 3 middle-left, 4 middle-right, 5 bottom-left, 6 bottom-right.
    var pattern = Int(scalar.value - 0x1FB00) + 1
    if pattern >= 21 { pattern += 1 }
    if pattern >= 42 { pattern += 1 }
    let leftW = (w / 2).rounded(.down)
    let topH = (h / 3).rounded()
    let middleH = (h * 2 / 3).rounded() - topH
    let bottomH = h - topH - middleH
    let rowsFromBottom: [(y: CGFloat, height: CGFloat)] = [
      (bottomH + middleH, topH), (bottomH, middleH), (0, bottomH),
    ]
    var rects: [FilledRect] = []
    for sextant in 0..<6 where pattern & (1 << sextant) != 0 {
      let row = rowsFromBottom[sextant / 2]
      let isLeft = sextant % 2 == 0
      let rect = CGRect(
        x: origin.x + (isLeft ? 0 : leftW),
        y: origin.y + row.y,
        width: isLeft ? leftW : w - leftW,
        height: row.height)
      rects.append(FilledRect(rect: rect, color: foreground))
    }
    return rects
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
