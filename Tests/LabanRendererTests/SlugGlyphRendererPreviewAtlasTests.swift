import CoreGraphics
import Foundation
import Metal
import XCTest

@testable import LabanRenderer

/// Confirms `.sidebarPreview`-sourced glyph runs resolve against the third,
/// dedicated `previewFontAtlas` rather than silently falling back to the
/// terminal or sidebar atlas (execplans/active/sidebar-hover-preview.md,
/// Milestone 2).
final class SlugGlyphRendererPreviewAtlasTests: XCTestCase {
  func testSidebarPreviewSourceUsesPreviewAtlasPointSize() throws {
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }
    let terminalAtlas = FontAtlas(pointSize: 16)
    let sidebarAtlas = FontAtlas(pointSize: 11)
    let previewAtlas = FontAtlas(pointSize: 7)
    let renderer = try XCTUnwrap(
      SlugGlyphRenderer(
        fontAtlas: terminalAtlas,
        sidebarFontAtlas: sidebarAtlas,
        previewFontAtlas: previewAtlas,
        pixelWidth: 200,
        pixelHeight: 80,
        scale: 1))
    renderer.waitForFrameCompletion = true
    renderer.presentsToLayer = false

    XCTAssertTrue(
      renderer.render(
        [
          .glyphRun(
            origin: CGPoint(x: 4, y: 20),
            text: "preview",
            foreground: 0xFFFF_FFFF,
            background: 0x0000_00FF,
            attributes: [],
            source: .sidebarPreview)
        ],
        damage: .full))

    XCTAssertEqual(
      renderer.lastFrameGlyphFontSizes, [Double(previewAtlas.pointSize)],
      "a .sidebarPreview glyph run must resolve against previewFontAtlas, not fontAtlas or sidebarFontAtlas")
  }

  func testSidebarPreviewSourceIsDistinctFromSidebarAndTerminalAtlases() throws {
    guard MTLCreateSystemDefaultDevice() != nil else {
      throw XCTSkip("no Metal device available")
    }
    let terminalAtlas = FontAtlas(pointSize: 20)
    let sidebarAtlas = FontAtlas(pointSize: 14)
    let previewAtlas = FontAtlas(pointSize: 9)
    let renderer = try XCTUnwrap(
      SlugGlyphRenderer(
        fontAtlas: terminalAtlas,
        sidebarFontAtlas: sidebarAtlas,
        previewFontAtlas: previewAtlas,
        pixelWidth: 240,
        pixelHeight: 100,
        scale: 1))
    renderer.waitForFrameCompletion = true
    renderer.presentsToLayer = false

    XCTAssertTrue(
      renderer.render(
        [
          .glyphRun(
            origin: CGPoint(x: 4, y: 24),
            text: "T",
            foreground: 0xFFFF_FFFF,
            background: 0x0000_00FF,
            attributes: [],
            source: .terminal),
          .glyphRun(
            origin: CGPoint(x: 4, y: 48),
            text: "S",
            foreground: 0xFFFF_FFFF,
            background: 0x0000_00FF,
            attributes: [],
            source: .sidebar),
          .glyphRun(
            origin: CGPoint(x: 4, y: 72),
            text: "P",
            foreground: 0xFFFF_FFFF,
            background: 0x0000_00FF,
            attributes: [],
            source: .sidebarPreview),
        ],
        damage: .full))

    XCTAssertEqual(
      Set(renderer.lastFrameGlyphFontSizes),
      Set([
        Double(terminalAtlas.pointSize), Double(sidebarAtlas.pointSize),
        Double(previewAtlas.pointSize),
      ]),
      "terminal/sidebar/preview sources must each resolve their own distinct atlas")
  }
}
