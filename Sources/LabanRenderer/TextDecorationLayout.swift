import CoreGraphics
import Foundation

struct TextDecorationLayout: Equatable {
  var thickness: CGFloat
  var underlineRects: [CGRect]
  var curlyUnderlinePoints: [CGPoint]
  var strikethroughRect: CGRect?
  var overlineRect: CGRect?

  static func make(
    origin: CGPoint,
    cellCount: Int,
    attributes: TextAttributes,
    underlineStyle: UnderlineStyle,
    cellAdvance: CGFloat,
    cellHeight: CGFloat,
    descent: CGFloat,
    scale: CGFloat,
    phaseOriginX: CGFloat? = nil
  ) -> TextDecorationLayout? {
    let drawsUnderline = attributes.contains(.underline) || underlineStyle != .none
    let drawsStrike = attributes.contains(.strikethrough)
    let drawsOverline = attributes.contains(.overline)
    guard drawsUnderline || drawsStrike || drawsOverline, cellCount > 0 else {
      return nil
    }

    let width = CGFloat(cellCount) * cellAdvance
    let thickness = max(1.0 / max(scale, 1), 1)
    let underlineY = origin.y + max(1, floor(descent * 0.45))
    // Patterned underlines (dashed/dotted/curly) seed their phase from this x.
    // When a continuous terminal underline is split into several style runs
    // (a mid-span foreground/hyperlink/colour change), each run passes the
    // shared row origin so the pattern stays continuous across the boundary
    // instead of restarting at every run's local left edge. Defaults to
    // origin.x, which keeps a single, un-split run byte-identical to before.
    let phaseX = phaseOriginX ?? origin.x
    let runEnd = origin.x + width

    var underlineRects: [CGRect] = []
    var curlyUnderlinePoints: [CGPoint] = []

    if drawsUnderline {
      let style: UnderlineStyle = underlineStyle == .none ? .single : underlineStyle
      switch style {
      case .none:
        break
      case .single:
        underlineRects.append(CGRect(x: origin.x, y: underlineY, width: width, height: thickness))
      case .double:
        underlineRects.append(CGRect(x: origin.x, y: underlineY, width: width, height: thickness))
        let gap = max(thickness, 1)
        underlineRects.append(
          CGRect(x: origin.x, y: underlineY + thickness + gap, width: width, height: thickness))
      case .curly:
        let amplitude = max(thickness * 1.2, 1.0)
        let period = max(cellAdvance, 6)
        let baseY = underlineY + thickness * 0.5
        let steps = max(Int(width / 1.5), 8)
        curlyUnderlinePoints.reserveCapacity(steps + 1)
        for i in 0...steps {
          let t = CGFloat(i) / CGFloat(steps)
          let x = origin.x + width * t
          let y =
            baseY + amplitude
            * CGFloat(sin((Double(x - phaseX) / Double(period)) * 2 * .pi))
          curlyUnderlinePoints.append(CGPoint(x: x, y: y))
        }
      case .dotted:
        let dot = max(thickness, 1)
        let stride = dot * 2
        var x = phaseX
        if x < origin.x { x += (((origin.x - x) / stride).rounded(.up)) * stride }
        while x < runEnd {
          underlineRects.append(CGRect(x: x, y: underlineY, width: dot, height: thickness))
          x += stride
        }
      case .dashed:
        let dash = max(cellAdvance * 0.5, 3)
        let gap = max(cellAdvance * 0.25, 2)
        let stride = dash + gap
        var x = phaseX
        if x < origin.x { x += (((origin.x - x) / stride).rounded(.down)) * stride }
        while x < runEnd {
          let segmentStart = max(x, origin.x)
          let segmentEnd = min(x + dash, runEnd)
          if segmentEnd > segmentStart {
            underlineRects.append(
              CGRect(
                x: segmentStart, y: underlineY,
                width: segmentEnd - segmentStart, height: thickness))
          }
          x += stride
        }
      }
    }

    return TextDecorationLayout(
      thickness: thickness,
      underlineRects: underlineRects,
      curlyUnderlinePoints: curlyUnderlinePoints,
      strikethroughRect: drawsStrike
        ? CGRect(
          x: origin.x,
          y: origin.y + floor(cellHeight * 0.52),
          width: width,
          height: thickness)
        : nil,
      overlineRect: drawsOverline
        ? CGRect(
          x: origin.x,
          y: origin.y + cellHeight - thickness - 1,
          width: width,
          height: thickness)
        : nil
    )
  }
}
