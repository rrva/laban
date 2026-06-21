import CoreGraphics
import CoreText
import Metal
import XCTest

@testable import LabanRenderer

final class ColorEmojiTests: XCTestCase {
  override func setUp() {
    super.setUp()
    UserDefaults.standard.removeObject(forKey: EmojiRenderingSettings.defaultsKey)
  }

  override func tearDown() {
    UserDefaults.standard.removeObject(forKey: EmojiRenderingSettings.defaultsKey)
    super.tearDown()
  }

  func testEmojiRendersWithColorPixelsInColorMode() throws {
    EmojiRenderingSettings.set(.color)

    let stats = try renderEmojiAndScanPixels()

    XCTAssertGreaterThan(stats.nonBackground, 0, "emoji must draw visible pixels")
    XCTAssertGreaterThan(
      stats.nonGray,
      20,
      "color mode must produce non-grayscale pixels for Apple Color Emoji")
  }

  func testMonochromeModePreservesTintedMaskPath() throws {
    EmojiRenderingSettings.set(.monochrome)

    let stats = try renderEmojiAndScanPixels()

    XCTAssertGreaterThan(stats.nonBackground, 0, "monochrome emoji must still draw")
    XCTAssertEqual(
      stats.nonGray,
      0,
      "monochrome mode should render the emoji through a grayscale/tinted mask")
  }

  func testColorGlyphAtlasKeepsEmojiInsideTwoCells() throws {
    guard let device = MTLCreateSystemDefaultDevice() else {
      throw XCTSkip("no Metal device available")
    }

    let fontAtlas = FontAtlas(pointSize: 18, fontName: "Helvetica")
    let cell = fontAtlas.cellSize
    guard
      let atlas = ColorGlyphAtlas(
        device: device,
        cellWidth: cell.width,
        cellHeight: cell.height,
        descent: fontAtlas.descent,
        scale: 1,
        textureSize: 128)
    else {
      return XCTFail("ColorGlyphAtlas init failed")
    }

    let entry = try XCTUnwrap(
      atlas.entry(
        character: "😀",
        font: fontAtlas.font,
        boldFallback: false,
        italicFallback: false))
    XCTAssertEqual(
      entry.logicalWidth,
      cell.width * 2,
      accuracy: 0.001,
      "color emoji atlas entries must preserve the two-cell metric")
    XCTAssertLessThanOrEqual(entry.pixelWidth, Int(ceil(cell.width * 2)))
  }

  private struct PixelStats {
    var nonBackground = 0
    var nonGray = 0
  }

  private func renderEmojiAndScanPixels() throws -> PixelStats {
    let fontAtlas = FontAtlas(pointSize: 32, fontName: "Helvetica")
    let width = Int(ceil(fontAtlas.cellSize.width * 3))
    let height = Int(ceil(fontAtlas.cellSize.height))
    let surface = BitmapSurface(width: width, height: height)
    let renderer = SoftwareRenderer(surface: surface, fontAtlas: fontAtlas)
    renderer.render([
      .rect(
        CGRect(x: 0, y: 0, width: surface.logicalWidth, height: surface.logicalHeight),
        color: 0x0000_00FF,
        source: .terminal),
      .glyphRun(
        origin: .zero,
        text: "😀",
        foreground: 0xFFFF_FFFF,
        background: 0x0000_00FF,
        attributes: [],
        source: .terminal),
    ])

    var stats = PixelStats()
    for y in 0..<surface.height {
      for x in 0..<surface.width {
        guard let pixel = surface.pixel(x: x, y: y), pixel != 0x0000_00FF else { continue }
        stats.nonBackground += 1
        let r = Int((pixel >> 24) & 0xFF)
        let g = Int((pixel >> 16) & 0xFF)
        let b = Int((pixel >> 8) & 0xFF)
        if abs(r - g) > 4 || abs(g - b) > 4 || abs(r - b) > 4 {
          stats.nonGray += 1
        }
      }
    }
    return stats
  }
}
