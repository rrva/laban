import CoreGraphics
import CoreText
import Foundation

public struct GlyphQuadraticCurve: Equatable {
  public let p0: CGPoint
  public let p1: CGPoint
  public let p2: CGPoint

  public init(p0: CGPoint, p1: CGPoint, p2: CGPoint) {
    self.p0 = p0
    self.p1 = p1
    self.p2 = p2
  }
}

public struct GlyphContour: Equatable {
  public let seed: CGPoint
  public let curveStart: Int
  public let curveCount: Int

  public init(seed: CGPoint, curveStart: Int, curveCount: Int) {
    self.seed = seed
    self.curveStart = curveStart
    self.curveCount = curveCount
  }
}

public struct GlyphCurveOutline: Equatable {
  public let glyph: CGGlyph
  public let bounds: CGRect
  public let curves: [GlyphQuadraticCurve]
  public let contours: [GlyphContour]

  public init(
    glyph: CGGlyph,
    bounds: CGRect,
    curves: [GlyphQuadraticCurve],
    contours: [GlyphContour]
  ) {
    self.glyph = glyph
    self.bounds = bounds.standardized
    self.curves = curves
    self.contours = contours
  }

  public func applying(_ transform: CGAffineTransform) -> GlyphCurveOutline {
    let transformedCurves = curves.map { curve in
      GlyphQuadraticCurve(
        p0: curve.p0.applying(transform),
        p1: curve.p1.applying(transform),
        p2: curve.p2.applying(transform))
    }
    let transformedContours = contours.map { contour in
      GlyphContour(
        seed: contour.seed.applying(transform),
        curveStart: contour.curveStart,
        curveCount: contour.curveCount)
    }
    let transformedPoints = transformedCurves.flatMap { [$0.p0, $0.p1, $0.p2] }
    let transformedBounds =
      transformedPoints.dropFirst().reduce(
        CGRect(origin: transformedPoints.first ?? .zero, size: .zero)
      ) { bounds, point in
        bounds.union(CGRect(origin: point, size: .zero))
      }
    return GlyphCurveOutline(
      glyph: glyph,
      bounds: transformedBounds,
      curves: transformedCurves,
      contours: transformedContours)
  }
}

public final class GlyphCurveStore {
  /// Outline geometry is a pure function of the font's *visual* identity: its
  /// PostScript name, point size, the glyph, and the text matrix (transformed
  /// fonts shear/scale the path). Keying on those — NOT `ObjectIdentifier(font)`,
  /// the bare object address — makes the cache immune to CTFont address reuse: a
  /// freed transient zoom font cannot alias a new font at a different size, which
  /// was the mixed-glyph-size zoom bug. It also lets distinct CTFont objects that
  /// describe the same rendered glyph share an entry.
  private struct Key: Hashable {
    let postScriptName: String
    let pointSize: CGFloat
    let glyph: CGGlyph
    let m11: CGFloat
    let m12: CGFloat
    let m21: CGFloat
    let m22: CGFloat
  }

  private var outlines: [Key: GlyphCurveOutline] = [:]
  private var missingOutlines: Set<Key> = []

  public init() {}

  private func key(for glyph: CGGlyph, font: CTFont) -> Key {
    let m = CTFontGetMatrix(font)
    return Key(
      postScriptName: CTFontCopyPostScriptName(font) as String,
      pointSize: CTFontGetSize(font),
      glyph: glyph,
      m11: m.a, m12: m.b, m21: m.c, m22: m.d)
  }

  /// Drop all cached outlines. With the visual-identity key above this is only
  /// memory hygiene (e.g. a font-family change), not a correctness requirement —
  /// a reused CTFont address can no longer alias a stale entry.
  public func invalidate() {
    outlines.removeAll(keepingCapacity: true)
    missingOutlines.removeAll(keepingCapacity: true)
  }

  public func outline(for glyph: CGGlyph, font: CTFont) -> GlyphCurveOutline? {
    let key = key(for: glyph, font: font)
    if let cached = outlines[key] { return cached }
    if missingOutlines.contains(key) { return nil }

    guard let path = CTFontCreatePathForGlyph(font, glyph, nil),
      !path.isEmpty
    else {
      missingOutlines.insert(key)
      return nil
    }

    guard
      let outline = Self.extractOutline(
        from: path, glyph: glyph, cubicTolerance: CTFontGetSize(font) * Self.cubicToleranceEm)
    else {
      missingOutlines.insert(key)
      return nil
    }
    outlines[key] = outline
    return outline
  }

  /// Largest allowed distance between a CFF cubic and its quadratic
  /// replacement, as a fraction of the em: about 0.14 device pixels at 144
  /// pixels per em, the top of the continuous-zoom range.
  public static let cubicToleranceEm: CGFloat = 1.0 / 1024

  /// Deepest cubic subdivision: at most 2^3 pieces of two quadratics each,
  /// which bounds band-list growth for pathological outlines.
  static let maxCubicSubdivisionDepth = 3

  public static func extractOutline(
    from path: CGPath, glyph: CGGlyph = 0, cubicTolerance: CGFloat = .infinity
  ) -> GlyphCurveOutline? {
    var builder = OutlineBuilder(
      glyph: glyph, pathBounds: path.boundingBoxOfPath, cubicTolerance: cubicTolerance)
    path.applyWithBlock { elementPointer in
      let element = elementPointer.pointee
      switch element.type {
      case .moveToPoint:
        builder.move(to: element.points[0])
      case .addLineToPoint:
        builder.line(to: element.points[0])
      case .addQuadCurveToPoint:
        builder.quad(control: element.points[0], to: element.points[1])
      case .addCurveToPoint:
        builder.cubic(
          control1: element.points[0],
          control2: element.points[1],
          to: element.points[2])
      case .closeSubpath:
        builder.closeContour()
      @unknown default:
        break
      }
    }
    return builder.finish()
  }

  /// Quadratics within `tolerance` of the cubic: the two-quadratic midpoint
  /// split when it is close enough, otherwise the cubic is halved (de
  /// Casteljau) and each half approximated again, down to
  /// `maxCubicSubdivisionDepth`.
  public static func approximateCubic(
    p0: CGPoint,
    p1: CGPoint,
    p2: CGPoint,
    p3: CGPoint,
    tolerance: CGFloat,
    depth: Int = 0
  ) -> [GlyphQuadraticCurve] {
    let split = splitCubicToQuadratics(p0: p0, p1: p1, p2: p2, p3: p3)
    guard tolerance.isFinite, depth < maxCubicSubdivisionDepth,
      splitDeviation(p0: p0, p1: p1, p2: p2, p3: p3, split: split) > tolerance
    else { return [split.0, split.1] }
    let p01 = p0.lerp(to: p1, t: 0.5)
    let p12 = p1.lerp(to: p2, t: 0.5)
    let p23 = p2.lerp(to: p3, t: 0.5)
    let p012 = p01.lerp(to: p12, t: 0.5)
    let p123 = p12.lerp(to: p23, t: 0.5)
    let mid = p012.lerp(to: p123, t: 0.5)
    return approximateCubic(
      p0: p0, p1: p01, p2: p012, p3: mid, tolerance: tolerance, depth: depth + 1)
      + approximateCubic(
        p0: mid, p1: p123, p2: p23, p3: p3, tolerance: tolerance, depth: depth + 1)
  }

  /// Parametric distance between the cubic and its two-quadratic split at a
  /// few interior samples. Parametric distance bounds the geometric error
  /// from above, so passing this test never under-subdivides at the samples.
  static func splitDeviation(
    p0: CGPoint, p1: CGPoint, p2: CGPoint, p3: CGPoint,
    split: (GlyphQuadraticCurve, GlyphQuadraticCurve)
  ) -> CGFloat {
    var worst: CGFloat = 0
    for t in [0.125, 0.25, 0.375, 0.625, 0.75, 0.875] as [CGFloat] {
      let u = 1 - t
      let cubic = CGPoint(
        x: u * u * u * p0.x + 3 * u * u * t * p1.x + 3 * u * t * t * p2.x + t * t * t * p3.x,
        y: u * u * u * p0.y + 3 * u * u * t * p1.y + 3 * u * t * t * p2.y + t * t * t * p3.y)
      let quadratic = t < 0.5 ? split.0 : split.1
      let s = t < 0.5 ? t * 2 : t * 2 - 1
      let v = 1 - s
      let approx = CGPoint(
        x: v * v * quadratic.p0.x + 2 * v * s * quadratic.p1.x + s * s * quadratic.p2.x,
        y: v * v * quadratic.p0.y + 2 * v * s * quadratic.p1.y + s * s * quadratic.p2.y)
      worst = max(worst, hypot(cubic.x - approx.x, cubic.y - approx.y))
    }
    return worst
  }

  public static func lineAsQuadratic(from p0: CGPoint, to p1: CGPoint) -> GlyphQuadraticCurve {
    GlyphQuadraticCurve(p0: p0, p1: p0.lerp(to: p1, t: 0.5), p2: p1)
  }

  public static func splitCubicToQuadratics(
    p0: CGPoint,
    p1: CGPoint,
    p2: CGPoint,
    p3: CGPoint
  ) -> (GlyphQuadraticCurve, GlyphQuadraticCurve) {
    let c0 = p0.lerp(to: p1, t: 0.75)
    let c1 = p3.lerp(to: p2, t: 0.75)
    let m = c0.lerp(to: c1, t: 0.5)
    return (
      GlyphQuadraticCurve(p0: p0, p1: c0, p2: m),
      GlyphQuadraticCurve(p0: m, p1: c1, p2: p3)
    )
  }
}

public enum GlyphCurveCPUOracle {
  private static let epsilon = 1e-9

  public static func windingNumber(
    at sample: CGPoint,
    in outline: GlyphCurveOutline
  ) -> Int {
    var winding = 0
    for contour in outline.contours {
      let end = contour.curveStart + contour.curveCount
      guard contour.curveStart >= 0, end <= outline.curves.count else { continue }
      for curve in outline.curves[contour.curveStart..<end] {
        winding += windingContribution(curve: curve, sample: sample)
      }
    }
    return winding
  }

  public static func coverage(at sample: CGPoint, in outline: GlyphCurveOutline) -> Double {
    guard outline.bounds.insetBy(dx: -epsilon, dy: -epsilon).contains(sample) else {
      return 0
    }
    return min(Double(abs(windingNumber(at: sample, in: outline))), 1)
  }

  public static func rasterizeCoverage(
    outline: GlyphCurveOutline,
    width: Int,
    height: Int,
    samplesPerAxis: Int,
    pixelToGlyph: (Int, Int, Double, Double) -> CGPoint
  ) -> [Double] {
    precondition(width > 0 && height > 0)
    precondition(samplesPerAxis > 0)
    var pixels = [Double](repeating: 0, count: width * height)
    let sampleWeight = 1.0 / Double(samplesPerAxis * samplesPerAxis)
    for y in 0..<height {
      for x in 0..<width {
        var sum = 0.0
        for sy in 0..<samplesPerAxis {
          let fy = (Double(sy) + 0.5) / Double(samplesPerAxis)
          for sx in 0..<samplesPerAxis {
            let fx = (Double(sx) + 0.5) / Double(samplesPerAxis)
            sum += coverage(at: pixelToGlyph(x, y, fx, fy), in: outline)
          }
        }
        pixels[y * width + x] = sum * sampleWeight
      }
    }
    return pixels
  }

  private static func windingContribution(
    curve: GlyphQuadraticCurve,
    sample: CGPoint
  ) -> Int {
    let x0 = Double(curve.p0.x - sample.x)
    let y0 = Double(curve.p0.y - sample.y)
    let x1 = Double(curve.p1.x - sample.x)
    let y1 = Double(curve.p1.y - sample.y)
    let x2 = Double(curve.p2.x - sample.x)
    let y2 = Double(curve.p2.y - sample.y)

    let a = y0 - 2 * y1 + y2
    let b = y0 - y1
    let c = y0

    if abs(a) <= epsilon {
      guard abs(b) > epsilon else { return 0 }
      let t = c / (2 * b)
      guard rootIsValid(t, x0: x0, x1: x1, x2: x2) else { return 0 }
      // derivative = -2*b; b>0 => downward crossing => +1.
      return b > 0 ? 1 : -1
    }

    // FMA keeps b*b - a*c at a single rounding (matches the Metal kernel).
    let discriminant = fma(b, b, -a * c)
    if discriminant <= 0 {
      return 0
    }

    let root = discriminant.squareRoot()
    // Numerically stable (Vieta / Numerical Recipes) roots of
    // a*t^2 - 2*b*t + c = 0; avoids catastrophic cancellation when |a| is tiny,
    // i.e. for straight strokes encoded as collinear quadratics.
    let s = b + (b >= 0 ? root : -root)
    let t0: Double  // downward crossing (+1) = (b - root)/a
    let t1: Double  // upward crossing (-1) = (b + root)/a
    if b >= 0 {
      t0 = c / s
      t1 = s / a
    } else {
      t0 = s / a
      t1 = c / s
    }
    var winding = 0
    if rootIsValid(t0, x0: x0, x1: x1, x2: x2) {
      winding += 1
    }
    if rootIsValid(t1, x0: x0, x1: x1, x2: x2) {
      winding -= 1
    }
    return winding
  }

  private static func rootIsValid(
    _ t: Double,
    x0: Double,
    x1: Double,
    x2: Double
  ) -> Bool {
    guard t >= -epsilon, t < 1 - epsilon else { return false }
    let clamped = max(0, min(t, 1))
    let oneMinusT = 1 - clamped
    let x =
      oneMinusT * oneMinusT * x0
      + 2 * oneMinusT * clamped * x1
      + clamped * clamped * x2
    return x >= -epsilon
  }
}

private struct OutlineBuilder {
  let glyph: CGGlyph
  let pathBounds: CGRect
  let cubicTolerance: CGFloat

  var curves: [GlyphQuadraticCurve] = []
  var contours: [GlyphContour] = []

  private var currentSeed: CGPoint?
  private var currentPoint: CGPoint?
  private var currentStart = 0

  init(glyph: CGGlyph, pathBounds: CGRect, cubicTolerance: CGFloat) {
    self.glyph = glyph
    self.pathBounds = pathBounds
    self.cubicTolerance = cubicTolerance
  }

  mutating func move(to point: CGPoint) {
    finishOpenContour()
    currentSeed = point
    currentPoint = point
    currentStart = curves.count
  }

  mutating func line(to point: CGPoint) {
    guard let current = currentPoint else {
      move(to: point)
      return
    }
    appendLine(from: current, to: point)
    currentPoint = point
  }

  mutating func quad(control: CGPoint, to point: CGPoint) {
    guard let current = currentPoint else {
      move(to: point)
      return
    }
    appendCurve(GlyphQuadraticCurve(p0: current, p1: control, p2: point))
    currentPoint = point
  }

  mutating func cubic(control1: CGPoint, control2: CGPoint, to point: CGPoint) {
    guard let current = currentPoint else {
      move(to: point)
      return
    }
    for curve in GlyphCurveStore.approximateCubic(
      p0: current, p1: control1, p2: control2, p3: point, tolerance: cubicTolerance)
    {
      appendCurve(curve)
    }
    currentPoint = point
  }

  mutating func closeContour() {
    guard let seed = currentSeed else { return }
    if let current = currentPoint, !current.isApproximatelyEqual(to: seed) {
      appendLine(from: current, to: seed)
    }
    finishClosedContour()
  }

  mutating func finish() -> GlyphCurveOutline? {
    finishOpenContour()
    guard !curves.isEmpty, !contours.isEmpty else { return nil }
    let bounds = usableBounds()
    guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else {
      return nil
    }
    return GlyphCurveOutline(glyph: glyph, bounds: bounds, curves: curves, contours: contours)
  }

  private mutating func finishOpenContour() {
    guard let seed = currentSeed else { return }
    if let current = currentPoint, !current.isApproximatelyEqual(to: seed) {
      appendLine(from: current, to: seed)
    }
    finishClosedContour()
  }

  private mutating func finishClosedContour() {
    let count = curves.count - currentStart
    if count > 0, let seed = currentSeed {
      contours.append(GlyphContour(seed: seed, curveStart: currentStart, curveCount: count))
    }
    currentSeed = nil
    currentPoint = nil
    currentStart = curves.count
  }

  private mutating func appendLine(from p0: CGPoint, to p1: CGPoint) {
    guard !p0.isApproximatelyEqual(to: p1) else { return }
    appendCurve(GlyphCurveStore.lineAsQuadratic(from: p0, to: p1))
  }

  private mutating func appendCurve(_ curve: GlyphQuadraticCurve) {
    guard
      curve.p0.isFinitePoint,
      curve.p1.isFinitePoint,
      curve.p2.isFinitePoint
    else { return }
    guard
      !curve.p0.isApproximatelyEqual(to: curve.p1)
        || !curve.p1.isApproximatelyEqual(to: curve.p2)
    else { return }
    curves.append(curve)
  }

  private func usableBounds() -> CGRect {
    let standardized = pathBounds.standardized
    if !standardized.isNull, !standardized.isInfinite,
      standardized.width.isFinite, standardized.height.isFinite,
      standardized.width > 0, standardized.height > 0
    {
      return standardized
    }

    var minX = CGFloat.infinity
    var minY = CGFloat.infinity
    var maxX = -CGFloat.infinity
    var maxY = -CGFloat.infinity
    for curve in curves {
      for point in [curve.p0, curve.p1, curve.p2] {
        minX = min(minX, point.x)
        minY = min(minY, point.y)
        maxX = max(maxX, point.x)
        maxY = max(maxY, point.y)
      }
    }
    return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY).standardized
  }
}

extension CGPoint {
  fileprivate var isFinitePoint: Bool {
    x.isFinite && y.isFinite
  }

  fileprivate func lerp(to other: CGPoint, t: CGFloat) -> CGPoint {
    CGPoint(x: x + (other.x - x) * t, y: y + (other.y - y) * t)
  }

  fileprivate func isApproximatelyEqual(to other: CGPoint, epsilon: CGFloat = 1e-6) -> Bool {
    abs(x - other.x) <= epsilon && abs(y - other.y) <= epsilon
  }
}
