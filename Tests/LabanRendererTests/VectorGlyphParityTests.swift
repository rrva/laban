import CoreGraphics
import CoreText
import Foundation
import Metal
import XCTest

@testable import LabanRenderer

final class VectorGlyphParityTests: XCTestCase {
  private let artifactRoot = URL(
    fileURLWithPath: ".build/vector-glyph-parity",
    isDirectory: true)

  override func setUp() {
    super.setUp()
    try? FileManager.default.removeItem(at: artifactRoot)
  }

  func testRendererGlyphMasksMatchCPUOracleForPrintableASCII() throws {
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }

    let atlas = FontAtlas(pointSize: 24, fontName: nil)
    let renderer = try XCTUnwrap(
      VectorGlyphRenderer(
        fontAtlas: atlas,
        sidebarFontAtlas: atlas,
        pixelWidth: 512,
        pixelHeight: 256,
        scale: 1))
    let store = GlyphCurveStore()

    var checked = 0
    for value in 0x20...0x7E {
      let scalar = try XCTUnwrap(Unicode.Scalar(value))
      guard let glyph = glyph(for: scalar, font: atlas.font) else { continue }
      guard let outline = store.outline(for: glyph, font: atlas.font) else { continue }
      let actual = try XCTUnwrap(
        renderer.maskSnapshot(for: glyph, font: atlas.font),
        "renderer mask missing for U+\(String(format: "%04X", value))")
      let expected = cpuSingleSampleMask(
        outline: outline,
        width: actual.width,
        height: actual.height,
        origin: actual.origin)

      let comparison = compare(expected: expected, actual: actual.bytes)
      if comparison.mismatchedPixels > comparison.allowedMismatches {
        writeArtifacts(
          scalarValue: value,
          width: actual.width,
          height: actual.height,
          expected: expected,
          actual: actual.bytes)
      }

      XCTAssertLessThanOrEqual(
        comparison.mismatchedPixels,
        comparison.allowedMismatches,
        "U+\(String(format: "%04X", value)) edge mismatches, max delta \(comparison.maxDelta)")
      checked += 1
    }
    XCTAssertGreaterThan(checked, 80, "printable ASCII should exercise most outline glyphs")
  }

  func testSyntheticItalicMaskUsesShearedVectorOutline() throws {
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }

    let atlas = FontAtlas(pointSize: 24, fontName: nil)
    let renderer = try XCTUnwrap(
      VectorGlyphRenderer(
        fontAtlas: atlas,
        sidebarFontAtlas: atlas,
        pixelWidth: 512,
        pixelHeight: 256,
        scale: 1))
    let scalar = try XCTUnwrap(Unicode.Scalar("H"))
    let glyph = try XCTUnwrap(glyph(for: scalar, font: atlas.font))
    let regular = try XCTUnwrap(renderer.maskSnapshot(for: glyph, font: atlas.font))
    let syntheticItalic = try XCTUnwrap(
      renderer.maskSnapshot(for: glyph, font: atlas.font, syntheticItalic: true))

    let geometryDiffers =
      regular.width != syntheticItalic.width
      || regular.height != syntheticItalic.height
      || regular.origin != syntheticItalic.origin
    XCTAssertTrue(
      geometryDiffers || regular.bytes != syntheticItalic.bytes,
      "synthetic italic must not alias the regular vector mask")
  }

  func testDecorationStylesChangeVectorOutput() throws {
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }

    let baseline = try renderDecorationProbe(attributes: [], underlineStyle: .none)
    let styles: [(TextAttributes, UnderlineStyle, UInt32?)] = [
      ([.underline], .single, nil),
      ([], .double, nil),
      ([], .dotted, nil),
      ([], .dashed, nil),
      ([], .curly, nil),
      ([.strikethrough], .none, nil),
      ([.overline], .none, nil),
      ([.underline, .strikethrough, .overline], .single, 0x33_99_FF_FF),
    ]

    for (attributes, underlineStyle, underlineColor) in styles {
      let decorated = try renderDecorationProbe(
        attributes: attributes,
        underlineStyle: underlineStyle,
        underlineColor: underlineColor)
      XCTAssertNotEqual(
        decorated,
        baseline,
        "decoration style \(underlineStyle) attributes \(attributes) must affect vector output")
    }
  }

  func testRendererHandlesLiveSizedInstanceBatches() throws {
    // Regression: Metal's setVertexBytes path aborts above 4 KB. A normal
    // terminal-sized vector frame can exceed that with either rect or glyph
    // instances, so the renderer must use buffer-backed instance uploads.
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }

    let atlas = FontAtlas(pointSize: 14, fontName: nil)
    let renderer = try XCTUnwrap(
      VectorGlyphRenderer(
        fontAtlas: atlas,
        sidebarFontAtlas: atlas,
        pixelWidth: 1640,
        pixelHeight: 912,
        scale: 2))

    var commands: [FrameCommand] = []
    let cellW: CGFloat = 9
    let cellH: CGFloat = 19
    for row in 0..<48 {
      for col in 0..<160 {
        let r = UInt32((row * 7 + col) & 0xFF)
        let g = UInt32((col * 5 + row * 3) & 0xFF)
        let b = UInt32((row * col) & 0xFF)
        let color = (r << 24) | (g << 16) | (b << 8) | 0xFF
        commands.append(
          .rect(
            CGRect(
              x: CGFloat(col) * cellW,
              y: CGFloat(row) * cellH,
              width: cellW,
              height: cellH),
            color: color,
            source: .terminal))
      }
    }

    let ascii = (0x21...0x7E).map { String(UnicodeScalar($0)!) }.joined()
    let line = String(String(repeating: ascii, count: 2).prefix(160))
    for row in 0..<48 {
      commands.append(
        .glyphRun(
          origin: CGPoint(x: 0, y: CGFloat(row) * cellH),
          text: line,
          foreground: 0xEE_EE_EE_FF,
          background: 0x00_00_00_00,
          attributes: [],
          source: .terminal))
    }

    for _ in 0..<3 {
      XCTAssertTrue(renderer.render(commands, damage: .full))
      XCTAssertGreaterThan(try XCTUnwrap(renderer.pngData).count, 0)
    }
  }

  private func glyph(for scalar: Unicode.Scalar, font: CTFont) -> CGGlyph? {
    guard scalar.value <= UInt32(UInt16.max) else { return nil }
    var unit = UniChar(scalar.value)
    var glyph = CGGlyph()
    guard CTFontGetGlyphsForCharacters(font, &unit, &glyph, 1), glyph != 0 else {
      return nil
    }
    return glyph
  }

  private func renderDecorationProbe(
    attributes: TextAttributes,
    underlineStyle: UnderlineStyle,
    underlineColor: UInt32? = nil
  ) throws -> Data {
    let atlas = FontAtlas(pointSize: 24, fontName: nil)
    let renderer = try XCTUnwrap(
      VectorGlyphRenderer(
        fontAtlas: atlas,
        sidebarFontAtlas: atlas,
        pixelWidth: 420,
        pixelHeight: 96,
        scale: 1))
    let commands: [FrameCommand] = [
      .rect(CGRect(x: 0, y: 0, width: 420, height: 96), color: 0x10_10_10_FF, source: .terminal),
      .glyphRun(
        origin: CGPoint(x: 24, y: 32),
        text: "Decorations",
        foreground: 0xEE_EE_EE_FF,
        background: 0x10_10_10_FF,
        attributes: attributes,
        source: .terminal,
        underlineStyle: underlineStyle,
        underlineColor: underlineColor),
    ]
    XCTAssertTrue(renderer.render(commands, damage: .full))
    return try XCTUnwrap(renderer.pngData)
  }

  private func cpuSingleSampleMask(
    outline: GlyphCurveOutline,
    width: Int,
    height: Int,
    origin: CGPoint
  ) -> [UInt8] {
    GlyphCurveCPUOracle.rasterizeCoverage(
      outline: outline,
      width: width,
      height: height,
      samplesPerAxis: 1
    ) { x, row, fx, fy in
      CGPoint(
        x: Double(origin.x) + Double(x) + fx,
        y: Double(origin.y) + Double(height - 1 - row) + fy)
    }.map { UInt8(max(0, min(255, Int(($0 * 255).rounded())))) }
  }

  private struct MaskComparison {
    var mismatchedPixels: Int
    var allowedMismatches: Int
    var maxDelta: Int
  }

  private func compare(expected: [UInt8], actual: [UInt8]) -> MaskComparison {
    XCTAssertEqual(actual.count, expected.count)
    var mismatchedPixels = 0
    var maxDelta = 0
    for index in expected.indices {
      let delta = abs(Int(actual[index]) - Int(expected[index]))
      if delta > 3 {
        mismatchedPixels += 1
        maxDelta = max(maxDelta, delta)
      }
    }
    return MaskComparison(
      mismatchedPixels: mismatchedPixels,
      // Slash/backslash can land exactly on the sample line in the tighter
      // renderer mask snapshot; keep the same 5-pixel edge-tie floor recorded
      // for the M1 safe-math oracle while preserving the 1% cap for larger masks.
      allowedMismatches: max(5, Int((Double(expected.count) * 0.01).rounded(.up))),
      maxDelta: maxDelta)
  }

  private func writeArtifacts(
    scalarValue: Int,
    width: Int,
    height: Int,
    expected: [UInt8],
    actual: [UInt8]
  ) {
    try? FileManager.default.createDirectory(at: artifactRoot, withIntermediateDirectories: true)
    let diff = zip(expected, actual).map { UInt8(abs(Int($0) - Int($1))) }
    let name = "U+\(String(format: "%04X", scalarValue))"
    try? grayPNG(width: width, height: height, bytes: expected)?
      .write(to: artifactRoot.appendingPathComponent("\(name).expected.png"))
    try? grayPNG(width: width, height: height, bytes: actual)?
      .write(to: artifactRoot.appendingPathComponent("\(name).actual.png"))
    try? grayPNG(width: width, height: height, bytes: diff)?
      .write(to: artifactRoot.appendingPathComponent("\(name).diff.png"))
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
}
