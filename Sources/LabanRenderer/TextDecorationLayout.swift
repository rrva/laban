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
    scale: CGFloat
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
            baseY + amplitude * CGFloat(sin((Double(t) * Double(width) / Double(period)) * 2 * .pi))
          curlyUnderlinePoints.append(CGPoint(x: x, y: y))
        }
      case .dotted:
        let dot = max(thickness, 1)
        var x = origin.x
        while x < origin.x + width {
          underlineRects.append(CGRect(x: x, y: underlineY, width: dot, height: thickness))
          x += dot * 2
        }
      case .dashed:
        let dash = max(cellAdvance * 0.5, 3)
        let gap = max(cellAdvance * 0.25, 2)
        var x = origin.x
        while x < origin.x + width {
          let segmentWidth = min(dash, origin.x + width - x)
          underlineRects.append(
            CGRect(x: x, y: underlineY, width: segmentWidth, height: thickness))
          x += dash + gap
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
