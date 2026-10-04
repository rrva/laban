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
    phaseOriginX: CGFloat? = nil,
    underlineMetrics: (position: CGFloat, thickness: CGFloat)? = nil
  ) -> TextDecorationLayout? {
    let drawsUnderline = attributes.contains(.underline) || underlineStyle != .none
    let drawsStrike = attributes.contains(.strikethrough)
    let drawsOverline = attributes.contains(.overline)
    guard drawsUnderline || drawsStrike || drawsOverline, cellCount > 0 else {
      return nil
    }

    let width = CGFloat(cellCount) * cellAdvance
    let pixelScale = max(scale, 1)
    let thickness: CGFloat
    let underlineY: CGFloat
    if let metrics = underlineMetrics, metrics.thickness > 0 {
      // The font's own underline, snapped to device pixels and kept inside
      // the cell between its bottom edge and the baseline.
      thickness = max(1 / pixelScale, (metrics.thickness * pixelScale).rounded() / pixelScale)
      let baseline = origin.y + descent
      let top = baseline + metrics.position
      let snapped = ((top - thickness) * pixelScale).rounded(.down) / pixelScale
      underlineY = min(max(snapped, origin.y), baseline - thickness)
    } else {
      thickness = max(1.0 / max(scale, 1), 1)
      underlineY = origin.y + max(1, floor(descent * 0.45))
    }
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
        // With font metrics the second line goes below, toward the cell
        // bottom, so it never climbs into the baseline; without them (or when
        // there is no room below) it stacks above as before.
        let below = underlineY - thickness - gap
        let secondY =
          underlineMetrics != nil && below >= origin.y ? below : underlineY + thickness + gap
        underlineRects.append(
          CGRect(x: origin.x, y: secondY, width: width, height: thickness))
      case .curly:
        let amplitude = max(thickness * 1.2, 1.0)
        let period = max(cellAdvance, 6)
        let baseY = underlineY + thickness * 0.5
        // One segment per point: finer than the old 1.5pt staircase without
        // multiplying quads by the backing scale on wide underlined runs.
        let steps = max(Int(width), 8)
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

extension TextDecorationLayout {
  /// `rect` minus the sorted x intervals in `cuts`: the pieces of an
  /// underline left after skip-ink gaps.
  static func subtracting(_ cuts: [(CGFloat, CGFloat)], from rect: CGRect) -> [CGRect] {
    guard !cuts.isEmpty else { return [rect] }
    var pieces: [CGRect] = []
    var x = rect.minX
    for (start, end) in cuts {
      if end <= x { continue }
      if start >= rect.maxX { break }
      if start > x {
        pieces.append(CGRect(x: x, y: rect.minY, width: start - x, height: rect.height))
      }
      x = max(x, end)
      if x >= rect.maxX { break }
    }
    if x < rect.maxX {
      pieces.append(CGRect(x: x, y: rect.minY, width: rect.maxX - x, height: rect.height))
    }
    return pieces
  }
}
