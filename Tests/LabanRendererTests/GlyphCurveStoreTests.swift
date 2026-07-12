import CoreGraphics
import CoreText
import Foundation
import XCTest

@testable import LabanRenderer

final class GlyphCurveStoreTests: XCTestCase {
  private let store = GlyphCurveStore()

  func testWindingNumberKernelClassifiesSyntheticSquare() {
    let outline = makeOutline(points: [
      CGPoint(x: 0, y: 0),
      CGPoint(x: 0, y: 1),
      CGPoint(x: 1, y: 1),
      CGPoint(x: 1, y: 0),
    ])

    let inside = GlyphCurveCPUOracle.windingNumber(at: CGPoint(x: 0.5, y: 0.5), in: outline)
    let outside = GlyphCurveCPUOracle.windingNumber(at: CGPoint(x: 1.5, y: 0.5), in: outline)

    XCTAssertEqual(abs(inside), 1)
    XCTAssertEqual(abs(outside), 0)
    XCTAssertEqual(GlyphCurveCPUOracle.coverage(at: CGPoint(x: 0.5, y: 0.5), in: outline), 1)
    XCTAssertEqual(GlyphCurveCPUOracle.coverage(at: CGPoint(x: 1.5, y: 0.5), in: outline), 0)
  }

  func testAnalyticDiscCoverageMatchesQuadraticOracle() {
    let outline = makeCircleOutline(segmentCount: 96)
    let width = 10
    let height = 10
    let minX = -1.25
    let minY = -1.25
    let pixelSize = 0.25
    let actual = GlyphCurveCPUOracle.rasterizeCoverage(
      outline: outline,
      width: width,
      height: height,
      samplesPerAxis: 32
    ) { x, y, fx, fy in
      CGPoint(
        x: minX + (Double(x) + fx) * pixelSize,
        y: minY + (Double(y) + fy) * pixelSize)
    }

    for y in 0..<height {
      for x in 0..<width {
        let rect = CGRect(
          x: minX + Double(x) * pixelSize,
          y: minY + Double(y) * pixelSize,
          width: pixelSize,
          height: pixelSize)
        let expected = circleArea(in: rect) / (pixelSize * pixelSize)
        XCTAssertEqual(
          actual[y * width + x],
          expected,
          accuracy: 1.0 / 255.0,
          "pixel \(x),\(y)")
      }
    }
  }

  func testContourTopologyPreservesHolesAndDisconnectedMarks() throws {
    let font = FontAtlas(pointSize: 72, fontName: nil).font

    let o = try outline(for: "O", font: font)
    XCTAssertGreaterThanOrEqual(o.contours.count, 2)
    var topology = rasterTopology(o)
    XCTAssertGreaterThanOrEqual(topology.interiorEmptyComponents, 1, "O must preserve its hole")
    XCTAssertEqual(
      GlyphCurveCPUOracle.coverage(
        at: CGPoint(x: o.bounds.midX, y: o.bounds.midY),
        in: o),
      0,
      accuracy: 0.001,
      "O center should be empty")

    let i = try outline(for: "i", font: font)
    XCTAssertGreaterThanOrEqual(i.contours.count, 2)
    topology = rasterTopology(i)
    XCTAssertGreaterThanOrEqual(topology.filledComponents, 2, "i stem and tittle must be separate")

    let percent = try outline(for: "%", font: font)
    XCTAssertGreaterThanOrEqual(percent.contours.count, 3)
    topology = rasterTopology(percent)
    XCTAssertGreaterThanOrEqual(topology.filledComponents, 3, "% should have rings plus slash")
    XCTAssertGreaterThanOrEqual(topology.interiorEmptyComponents, 2, "% rings must keep holes")

    let eight = try outline(for: "8", font: font)
    topology = rasterTopology(eight)
    XCTAssertGreaterThanOrEqual(topology.interiorEmptyComponents, 2, "8 must keep both counters")

    let acute = try outline(forScalarValue: 0x0301, font: font)
    XCTAssertGreaterThanOrEqual(acute.contours.count, 1)
    topology = rasterTopology(acute)
    XCTAssertGreaterThanOrEqual(
      topology.filledComponents,
      1,
      "standalone combining acute must draw")
  }

  func testCubicSplitUsesWorkedExampleAndBoundedSampledDeviation() {
    let p0 = CGPoint(x: 0, y: 0)
    let p1 = CGPoint(x: 0, y: 4)
    let p2 = CGPoint(x: 4, y: 4)
    let p3 = CGPoint(x: 4, y: 0)

    let split = GlyphCurveStore.splitCubicToQuadratics(p0: p0, p1: p1, p2: p2, p3: p3)

    XCTAssertEqual(split.0.p1.x, 0, accuracy: 1e-6)
    XCTAssertEqual(split.0.p1.y, 3, accuracy: 1e-6)
    XCTAssertEqual(split.1.p1.x, 4, accuracy: 1e-6)
    XCTAssertEqual(split.1.p1.y, 3, accuracy: 1e-6)
    XCTAssertEqual(split.0.p2.x, 2, accuracy: 1e-6)
    XCTAssertEqual(split.0.p2.y, 3, accuracy: 1e-6)
    XCTAssertEqual(split.0.p2, split.1.p0)

    let deviation = sampledMaxDeviationFromCubic(
      p0: p0, p1: p1, p2: p2, p3: p3,
      quadratics: [split.0, split.1])
    XCTAssertLessThan(deviation, 0.15)
    XCTAssertGreaterThan(deviation, 0.10)
  }

  func testCoreTextAlphaComparisonForPrintableASCII() throws {
    let fontCases: [(label: String, font: CTFont)] = [
      ("JetBrainsMono", FontAtlas(pointSize: 24, fontName: nil).font),
      ("Menlo", CTFontCreateWithName("Menlo" as CFString, 24, nil)),
    ]

    let inputs = try fontCases.flatMap { fontCase in
      try (0x20...0x7E).map { value in
        let scalar = try XCTUnwrap(Unicode.Scalar(value))
        let glyph = try glyph(for: scalar, font: fontCase.font)
        return (
          label: fontCase.label,
          value: value,
          font: fontCase.font,
          glyph: glyph,
          outline: store.outline(for: glyph, font: fontCase.font)
        )
      }
    }
    let resultsLock = NSLock()
    var results: [(String, Int, GlyphCurveOutline?, RenderComparison)] = []
    DispatchQueue.concurrentPerform(iterations: inputs.count) { index in
      let input = inputs[index]
      let comparison = Self.renderComparison(
        font: input.font,
        glyph: input.glyph,
        outline: input.outline)
      resultsLock.lock()
      results.append((input.label, input.value, input.outline, comparison))
      resultsLock.unlock()
    }

    for result in results.sorted(by: {
      $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0
    }) {
      let fontLabel = result.0
      let value = result.1
      let outline = result.2
      let comparison = result.3

      if outline == nil {
        XCTAssertEqual(
          comparison.coreTextInkPixels,
          0,
          "\(fontLabel) U+\(String(format: "%04X", value)) should not have visible ink")
        continue
      }

      guard comparison.inkPixels > 0 else {
        XCTFail("\(fontLabel) U+\(String(format: "%04X", value)) produced no ink")
        continue
      }

      if comparison.meanAbsoluteDifference > 16.0
        || comparison.percentWithinSixtyFour < 0.98
        || abs(comparison.coverageRatio - 1) > 0.20
      {
        writeArtifacts(
          fontLabel: fontLabel,
          scalarValue: value,
          width: comparison.width,
          height: comparison.height,
          expected: comparison.expected,
          actual: comparison.actual,
          diff: comparison.diff)
      }

      XCTAssertLessThanOrEqual(
        comparison.meanAbsoluteDifference,
        16.0,
        "\(fontLabel) U+\(String(format: "%04X", value)) mean abs")
      XCTAssertGreaterThanOrEqual(
        comparison.percentWithinSixtyFour,
        0.98,
        "\(fontLabel) U+\(String(format: "%04X", value)) within ±64/255")
      XCTAssertEqual(
        comparison.coverageRatio,
        1,
        accuracy: 0.20,
        "\(fontLabel) U+\(String(format: "%04X", value)) total coverage ratio")
    }
  }

  // MARK: - Glyph lookup and topology

  private func outline(for character: Character, font: CTFont) throws -> GlyphCurveOutline {
    guard character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first else {
      throw XCTSkip("test helper only handles single-scalar characters")
    }
    return try outline(forScalarValue: scalar.value, font: font)
  }

  private func outline(forScalarValue value: UInt32, font: CTFont) throws -> GlyphCurveOutline {
    let scalar = try XCTUnwrap(Unicode.Scalar(value))
    let glyph = try glyph(for: scalar, font: font)
    guard let outline = store.outline(for: glyph, font: font) else {
      throw XCTSkip("font has no outline for U+\(String(format: "%04X", value))")
    }
    return outline
  }

  private func glyph(for scalar: Unicode.Scalar, font: CTFont) throws -> CGGlyph {
    guard scalar.value <= UInt32(UInt16.max) else {
      throw XCTSkip("scalar outside CTFontGetGlyphsForCharacters BMP helper")
    }
    var unit = UniChar(scalar.value)
    var glyph = CGGlyph()
    guard CTFontGetGlyphsForCharacters(font, &unit, &glyph, 1), glyph != 0 else {
      throw XCTSkip("font has no glyph for U+\(String(format: "%04X", scalar.value))")
    }
    return glyph
  }

  private struct Topology {
    let filledComponents: Int
    let interiorEmptyComponents: Int
  }

  private func rasterTopology(_ outline: GlyphCurveOutline, size: Int = 96) -> Topology {
    let padX = max(outline.bounds.width * 0.08, 1)
    let padY = max(outline.bounds.height * 0.08, 1)
    let bounds = outline.bounds.insetBy(dx: -padX, dy: -padY)
    var filled = [Bool](repeating: false, count: size * size)
    for y in 0..<size {
      for x in 0..<size {
        let sample = CGPoint(
          x: bounds.minX + (CGFloat(x) + 0.5) * bounds.width / CGFloat(size),
          y: bounds.minY + (CGFloat(y) + 0.5) * bounds.height / CGFloat(size))
        filled[y * size + x] = GlyphCurveCPUOracle.coverage(at: sample, in: outline) > 0.5
      }
    }
    let filledComponents = countComponents(mask: filled, width: size, height: size, target: true)
      .total
    let interiorEmptyComponents =
      countComponents(mask: filled, width: size, height: size, target: false)
      .interior
    return Topology(
      filledComponents: filledComponents,
      interiorEmptyComponents: interiorEmptyComponents)
  }

  private func countComponents(
    mask: [Bool],
    width: Int,
    height: Int,
    target: Bool
  ) -> (total: Int, interior: Int) {
    var visited = [Bool](repeating: false, count: mask.count)
    var total = 0
    var interior = 0
    var stack: [(Int, Int)] = []
    for y in 0..<height {
      for x in 0..<width {
        let index = y * width + x
        guard !visited[index], mask[index] == target else { continue }
        total += 1
        var touchesEdge = false
        visited[index] = true
        stack.append((x, y))
        while let point = stack.popLast() {
          if point.0 == 0 || point.1 == 0 || point.0 == width - 1 || point.1 == height - 1 {
            touchesEdge = true
          }
          for next in neighbors(point.0, point.1, width: width, height: height) {
            let nextIndex = next.1 * width + next.0
            guard !visited[nextIndex], mask[nextIndex] == target else { continue }
            visited[nextIndex] = true
            stack.append(next)
          }
        }
        if !touchesEdge {
          interior += 1
        }
      }
    }
    return (total, interior)
  }

  private func neighbors(
    _ x: Int,
    _ y: Int,
    width: Int,
    height: Int
  ) -> [(Int, Int)] {
    var result: [(Int, Int)] = []
    if x > 0 { result.append((x - 1, y)) }
    if x + 1 < width { result.append((x + 1, y)) }
    if y > 0 { result.append((x, y - 1)) }
    if y + 1 < height { result.append((x, y + 1)) }
    return result
  }

  // MARK: - CoreText comparison

  private struct RenderComparison {
    let width: Int
    let height: Int
    let expected: [UInt8]
    let actual: [UInt8]
    let diff: [UInt8]
    let inkPixels: Int
    let coreTextInkPixels: Int
    let meanAbsoluteDifference: Double
    let percentWithinSixtyFour: Double
    let coverageRatio: Double
  }

  private static func renderComparison(
    font: CTFont,
    glyph: CGGlyph,
    outline: GlyphCurveOutline?
  ) -> RenderComparison {
    var glyphCopy = glyph
    let glyphBounds = CTFontGetBoundingRectsForGlyphs(font, .default, &glyphCopy, nil, 1)
      .standardized
    var advance = CGSize.zero
    _ = CTFontGetAdvancesForGlyphs(font, .horizontal, &glyphCopy, &advance, 1)
    let pad: CGFloat = 4
    let fallbackBounds = CGRect(
      x: 0,
      y: -CTFontGetDescent(font),
      width: max(advance.width, 1),
      height: CTFontGetAscent(font) + CTFontGetDescent(font))
    let bounds: CGRect
    if !glyphBounds.isNull && glyphBounds.width > 0 && glyphBounds.height > 0 {
      bounds = glyphBounds
    } else {
      bounds = fallbackBounds
    }
    let minX = floor(min(bounds.minX, 0) - pad)
    let maxX = ceil(max(bounds.maxX, advance.width) + pad)
    let minY = floor(min(bounds.minY, fallbackBounds.minY) - pad)
    let maxY = ceil(max(bounds.maxY, fallbackBounds.maxY) + pad)
    let width = max(1, Int(maxX - minX))
    let height = max(1, Int(maxY - minY))

    let expected = renderCoreTextAlpha(
      font: font,
      glyph: glyph,
      width: width,
      height: height,
      drawPosition: CGPoint(x: -minX, y: -minY))
    let actual =
      outline.map {
        renderVectorAlpha(
          outline: $0,
          width: width,
          height: height,
          minX: minX,
          minY: minY)
      } ?? [UInt8](repeating: 0, count: width * height)
    let diff = zip(expected, actual).map { UInt8(abs(Int($0) - Int($1))) }
    let coreTextInkPixels = expected.filter { $0 > 0 }.count

    var inkPixels = 0
    var diffTotal = 0
    var withinSixtyFour = 0
    var expectedCoverageTotal = 0
    var actualCoverageTotal = 0
    for i in expected.indices {
      expectedCoverageTotal += Int(expected[i])
      actualCoverageTotal += Int(actual[i])
      guard expected[i] > 0 || actual[i] > 0 else { continue }
      inkPixels += 1
      let delta = Int(diff[i])
      diffTotal += delta
      if delta <= 64 { withinSixtyFour += 1 }
    }

    return RenderComparison(
      width: width,
      height: height,
      expected: expected,
      actual: actual,
      diff: diff,
      inkPixels: inkPixels,
      coreTextInkPixels: coreTextInkPixels,
      meanAbsoluteDifference: inkPixels == 0 ? 0 : Double(diffTotal) / Double(inkPixels),
      percentWithinSixtyFour: inkPixels == 0
        ? 1
        : Double(withinSixtyFour) / Double(inkPixels),
      coverageRatio: expectedCoverageTotal == 0
        ? 1
        : Double(actualCoverageTotal) / Double(expectedCoverageTotal))
  }

  private static func renderCoreTextAlpha(
    font: CTFont,
    glyph: CGGlyph,
    width: Int,
    height: Int,
    drawPosition: CGPoint
  ) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: width * height)
    bytes.withUnsafeMutableBytes { raw in
      guard
        let context = CGContext(
          data: raw.baseAddress,
          width: width,
          height: height,
          bitsPerComponent: 8,
          bytesPerRow: width,
          space: CGColorSpaceCreateDeviceGray(),
          bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue)
      else { return }
      context.setAllowsAntialiasing(true)
      context.setShouldAntialias(true)
      context.setAllowsFontSmoothing(false)
      context.setShouldSmoothFonts(false)
      context.setAllowsFontSubpixelPositioning(true)
      context.setShouldSubpixelPositionFonts(true)
      context.setAllowsFontSubpixelQuantization(false)
      context.setShouldSubpixelQuantizeFonts(false)
      context.setFillColor(CGColor(gray: 1, alpha: 1))
      context.textMatrix = .identity
      var glyphCopy = glyph
      var position = drawPosition
      CTFontDrawGlyphs(font, &glyphCopy, &position, 1, context)
    }
    return bytes
  }

  private static func renderVectorAlpha(
    outline: GlyphCurveOutline,
    width: Int,
    height: Int,
    minX: CGFloat,
    minY: CGFloat
  ) -> [UInt8] {
    let coverage = GlyphCurveCPUOracle.rasterizeCoverage(
      outline: outline,
      width: width,
      height: height,
      samplesPerAxis: 16
    ) { x, row, fx, fy in
      let cgY = Double(height - 1 - row) + fy
      return CGPoint(x: Double(minX) + Double(x) + fx, y: Double(minY) + cgY)
    }
    return coverage.map { UInt8(max(0, min(255, Int(($0 * 255).rounded())))) }
  }

  private func writeArtifacts(
    fontLabel: String,
    scalarValue: Int,
    width: Int,
    height: Int,
    expected: [UInt8],
    actual: [UInt8],
    diff: [UInt8]
  ) {
    let env = ProcessInfo.processInfo.environment
    let base = URL(fileURLWithPath: env["LABAN_ARTIFACTS"] ?? ".artifacts", isDirectory: true)
      .appendingPathComponent("GlyphCurveStoreTests", isDirectory: true)
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let name = "\(fontLabel)-U+\(String(format: "%04X", scalarValue))"
    try? grayPNG(width: width, height: height, bytes: expected)?
      .write(to: base.appendingPathComponent("\(name).expected.png"))
    try? grayPNG(width: width, height: height, bytes: actual)?
      .write(to: base.appendingPathComponent("\(name).actual.png"))
    try? grayPNG(width: width, height: height, bytes: diff)?
      .write(to: base.appendingPathComponent("\(name).diff.png"))
  }

  private func grayPNG(width: Int, height: Int, bytes: [UInt8]) -> Data? {
    let data = Data(bytes)
    guard let provider = CGDataProvider(data: data as CFData) else { return nil }
    guard
      let image = CGImage(
        width: width,
        height: height,
        bitsPerComponent: 8,
        bitsPerPixel: 8,
        bytesPerRow: width,
        space: CGColorSpaceCreateDeviceGray(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent)
    else { return nil }
    return PNGEncoder.encode(image)
  }

  // MARK: - Synthetic geometry

  private func makeOutline(points: [CGPoint]) -> GlyphCurveOutline {
    precondition(points.count >= 3)
    var curves: [GlyphQuadraticCurve] = []
    for i in points.indices {
      let next = points[(i + 1) % points.count]
      curves.append(GlyphCurveStore.lineAsQuadratic(from: points[i], to: next))
    }
    let bounds = points.reduce(CGRect.null) { partial, point in
      partial.union(CGRect(origin: point, size: .zero))
    }
    return GlyphCurveOutline(
      glyph: 0,
      bounds: bounds,
      curves: curves,
      contours: [GlyphContour(seed: points[0], curveStart: 0, curveCount: curves.count)])
  }

  private func makeCircleOutline(segmentCount: Int) -> GlyphCurveOutline {
    precondition(segmentCount >= 8)
    let delta = 2 * Double.pi / Double(segmentCount)
    var curves: [GlyphQuadraticCurve] = []
    for segment in 0..<segmentCount {
      let a0 = Double(segment) * delta
      let a1 = Double(segment + 1) * delta
      let mid = (a0 + a1) * 0.5
      let half = (a1 - a0) * 0.5
      let p0 = CGPoint(x: cos(a0), y: sin(a0))
      let p2 = CGPoint(x: cos(a1), y: sin(a1))
      let p1 = CGPoint(x: cos(mid) / cos(half), y: sin(mid) / cos(half))
      curves.append(GlyphQuadraticCurve(p0: p0, p1: p1, p2: p2))
    }
    return GlyphCurveOutline(
      glyph: 0,
      bounds: CGRect(x: -1, y: -1, width: 2, height: 2),
      curves: curves,
      contours: [GlyphContour(seed: curves[0].p0, curveStart: 0, curveCount: curves.count)])
  }

  private func circleArea(in rect: CGRect) -> Double {
    let x0 = max(Double(rect.minX), -1)
    let x1 = min(Double(rect.maxX), 1)
    guard x1 > x0 else { return 0 }
    let y0 = Double(rect.minY)
    let y1 = Double(rect.maxY)
    func verticalLength(_ x: Double) -> Double {
      let radiusY = sqrt(max(0, 1 - x * x))
      let lo = max(y0, -radiusY)
      let hi = min(y1, radiusY)
      return max(0, hi - lo)
    }
    return adaptiveSimpson(verticalLength, x0, x1, epsilon: 1e-9, maxDepth: 16)
  }

  private func adaptiveSimpson(
    _ f: (Double) -> Double,
    _ a: Double,
    _ b: Double,
    epsilon: Double,
    maxDepth: Int
  ) -> Double {
    let c = (a + b) * 0.5
    let fa = f(a)
    let fb = f(b)
    let fc = f(c)
    let whole = simpson(fa: fa, fb: fb, fc: fc, a: a, b: b)
    return adaptiveSimpsonRecursive(
      f, a, b, epsilon: epsilon, whole: whole, fa: fa, fb: fb, fc: fc, depth: maxDepth)
  }

  private func adaptiveSimpsonRecursive(
    _ f: (Double) -> Double,
    _ a: Double,
    _ b: Double,
    epsilon: Double,
    whole: Double,
    fa: Double,
    fb: Double,
    fc: Double,
    depth: Int
  ) -> Double {
    let c = (a + b) * 0.5
    let d = (a + c) * 0.5
    let e = (c + b) * 0.5
    let fd = f(d)
    let fe = f(e)
    let left = simpson(fa: fa, fb: fc, fc: fd, a: a, b: c)
    let right = simpson(fa: fc, fb: fb, fc: fe, a: c, b: b)
    let delta = left + right - whole
    if depth <= 0 || abs(delta) <= 15 * epsilon {
      return left + right + delta / 15
    }
    return adaptiveSimpsonRecursive(
      f, a, c, epsilon: epsilon * 0.5, whole: left, fa: fa, fb: fc, fc: fd, depth: depth - 1)
      + adaptiveSimpsonRecursive(
        f, c, b, epsilon: epsilon * 0.5, whole: right, fa: fc, fb: fb, fc: fe,
        depth: depth - 1)
  }

  private func simpson(fa: Double, fb: Double, fc: Double, a: Double, b: Double) -> Double {
    (b - a) * (fa + 4 * fc + fb) / 6
  }

  private func sampledMaxDeviationFromCubic(
    p0: CGPoint,
    p1: CGPoint,
    p2: CGPoint,
    p3: CGPoint,
    quadratics: [GlyphQuadraticCurve]
  ) -> CGFloat {
    var maxDeviation: CGFloat = 0
    for i in 0...32 {
      let t = CGFloat(i) / 32
      let cubicPoint = cubic(p0, p1, p2, p3, t: t)
      var nearest = CGFloat.infinity
      for curve in quadratics {
        for j in 0...256 {
          let q = CGFloat(j) / 256
          nearest = min(nearest, distance(cubicPoint, quadratic(curve, t: q)))
        }
      }
      maxDeviation = max(maxDeviation, nearest)
    }
    return maxDeviation
  }

  private func cubic(
    _ p0: CGPoint,
    _ p1: CGPoint,
    _ p2: CGPoint,
    _ p3: CGPoint,
    t: CGFloat
  ) -> CGPoint {
    let u = 1 - t
    return CGPoint(
      x: u * u * u * p0.x + 3 * u * u * t * p1.x + 3 * u * t * t * p2.x + t * t * t * p3.x,
      y: u * u * u * p0.y + 3 * u * u * t * p1.y + 3 * u * t * t * p2.y + t * t * t * p3.y)
  }

  private func quadratic(_ curve: GlyphQuadraticCurve, t: CGFloat) -> CGPoint {
    let u = 1 - t
    return CGPoint(
      x: u * u * curve.p0.x + 2 * u * t * curve.p1.x + t * t * curve.p2.x,
      y: u * u * curve.p0.y + 2 * u * t * curve.p1.y + t * t * curve.p2.y)
  }

  private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
    hypot(a.x - b.x, a.y - b.y)
  }
}
