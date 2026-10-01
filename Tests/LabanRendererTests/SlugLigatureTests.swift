import CoreGraphics
import Foundation
import ImageIO
import Metal
import XCTest

@testable import LabanRenderer

/// Slug draws programming-font ligatures in place of the per-cell glyphs when
/// `FontLigatureSettings` is on (ADR 0037), and is byte-for-byte unchanged
/// when it is off or the run has nothing to ligate.
final class SlugLigatureTests: XCTestCase {
  private let width = 200
  private let height = 80
  private let origin = CGPoint(x: 12, y: 32)
  private var atlas: FontAtlas!

  /// Registers rather than writes so nothing reaches the persistent domain
  /// shared with parallel test processes
  /// (execplans/active/test-userdefaults-isolation.md).
  private static func registerLigatures(_ enabled: Bool) {
    UserDefaults.standard.register(defaults: [
      FontLigatureSettings.enabledKey: enabled,
      EmojiRenderingSettings.defaultsKey: EmojiRenderingMode.monochrome.rawValue,
    ])
  }

  override func setUpWithError() throws {
    try super.setUpWithError()
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }
    if FontLigatureSettings.environmentOverride() != nil {
      throw XCTSkip("\(FontLigatureSettings.enabledEnvironmentKey) pins the setting")
    }
    // The bundled JetBrains Mono, independent of any user font pick.
    atlas = FontAtlas(pointSize: 18, fontName: nil)
  }

  override func tearDown() {
    Self.registerLigatures(false)
    super.tearDown()
  }

  func testArrowDrawsOneLigatureGlyphOnlyWhenEnabled() throws {
    let off = try render("->", ligatures: false)
    XCTAssertEqual(off.ligatureGlyphs, 0)

    let on = try render("->", ligatures: true)
    XCTAssertEqual(on.ligatureGlyphs, 1, "the spacer cell has no outline; one joined arrow")
    XCTAssertGreaterThan(
      meanAbsoluteDiff(off.image, on.image), 0.5,
      "the ligature arrow must differ visibly from a hyphen beside a greater-than")

    // The joined arrow still covers both cells: ink in the first (spacer)
    // cell comes from the second cell's glyph reaching back over it.
    let cell = atlas.cellSize.width
    let firstCell = Int(origin.x)..<Int(origin.x + cell)
    let secondCell = Int(origin.x + cell)..<Int(origin.x + 2 * cell)
    XCTAssertGreaterThan(inkCount(on.image, xRange: firstCell), 10)
    XCTAssertGreaterThan(inkCount(on.image, xRange: secondCell), 10)
    // And nothing spills past the two cells.
    let beyond = Int(ceil(origin.x + 2 * cell)) + 2..<width
    XCTAssertEqual(inkCount(on.image, xRange: beyond), 0)
  }

  func testRunsWithoutLigaturesRenderIdenticallyWhenEnabled() throws {
    let off = try render("hello, world - > fi", ligatures: false)
    let on = try render("hello, world - > fi", ligatures: true)
    XCTAssertEqual(on.ligatureGlyphs, 0)
    XCTAssertEqual(off.png, on.png, "enabling ligatures must not move non-ligature text")
  }

  func testLigatureRendersStableAcrossRepeatedFrames() throws {
    Self.registerLigatures(true)
    let renderer = try makeRenderer()
    let first = try renderFrame(renderer, text: "a != b")
    let second = try renderFrame(renderer, text: "a != b")
    XCTAssertEqual(renderer.rendererStatus.ligatureGlyphs, 1)
    XCTAssertEqual(first, second, "the cached shaping must reproduce the cold frame")
  }

  func testRefreshFontLigaturesTogglesLiveRenderer() throws {
    Self.registerLigatures(false)
    let renderer = try makeRenderer()
    _ = try renderFrame(renderer, text: "===")
    XCTAssertEqual(renderer.rendererStatus.ligatureGlyphs, 0)
    Self.registerLigatures(true)
    renderer.refreshFontLigatures()
    _ = try renderFrame(renderer, text: "===")
    XCTAssertEqual(renderer.rendererStatus.ligatureGlyphs, 1)
  }

  // MARK: - Helpers

  private struct Rendered {
    var png: Data
    var image: RGBAImage
    var ligatureGlyphs: Int?
  }

  private func render(_ text: String, ligatures: Bool) throws -> Rendered {
    Self.registerLigatures(ligatures)
    let renderer = try makeRenderer()
    let png = try renderFrame(renderer, text: text)
    return Rendered(
      png: png, image: try decodeRGBA(png),
      ligatureGlyphs: renderer.rendererStatus.ligatureGlyphs)
  }

  private func makeRenderer() throws -> SlugGlyphRenderer {
    let renderer = try XCTUnwrap(
      SlugGlyphRenderer(fontAtlas: atlas, pixelWidth: width, pixelHeight: height, scale: 1))
    renderer.waitForFrameCompletion = true
    renderer.presentsToLayer = false
    return renderer
  }

  private func renderFrame(_ renderer: SlugGlyphRenderer, text: String) throws -> Data {
    XCTAssertTrue(
      renderer.render(
        [
          .rect(
            CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)),
            color: 0x0000_00FF,
            source: .terminal),
          .glyphRun(
            origin: origin,
            text: text,
            foreground: 0xFFFF_FFFF,
            background: 0x0000_00FF,
            attributes: [],
            source: .terminal),
        ],
        damage: .full))
    return try XCTUnwrap(renderer.pngData)
  }

  private struct RGBAImage {
    var width: Int
    var height: Int
    var bytes: [UInt8]
  }

  private struct DecodeFailure: Error {}

  private func decodeRGBA(_ png: Data) throws -> RGBAImage {
    guard let source = CGImageSourceCreateWithData(png as CFData, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { throw DecodeFailure() }
    var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
    bytes.withUnsafeMutableBytes { raw in
      guard
        let context = CGContext(
          data: raw.baseAddress,
          width: image.width,
          height: image.height,
          bitsPerComponent: 8,
          bytesPerRow: image.width * 4,
          space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            | CGBitmapInfo.byteOrder32Big.rawValue)
      else { return }
      context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
    return RGBAImage(width: image.width, height: image.height, bytes: bytes)
  }

  private func inkCount(_ image: RGBAImage, xRange: Range<Int>) -> Int {
    var count = 0
    for y in 0..<image.height {
      for x in xRange where x >= 0 && x < image.width {
        if image.bytes[(y * image.width + x) * 4] > 64 { count += 1 }
      }
    }
    return count
  }

  private func meanAbsoluteDiff(_ lhs: RGBAImage, _ rhs: RGBAImage) -> Double {
    guard lhs.bytes.count == rhs.bytes.count, !lhs.bytes.isEmpty else { return .infinity }
    var total = 0
    for index in lhs.bytes.indices {
      total += abs(Int(lhs.bytes[index]) - Int(rhs.bytes[index]))
    }
    return Double(total) / Double(lhs.bytes.count)
  }
}
