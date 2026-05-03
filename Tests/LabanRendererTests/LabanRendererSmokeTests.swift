import CoreGraphics
import XCTest

@testable import LabanRenderer

final class LabanRendererSmokeTests: XCTestCase {

  // MARK: - FrameCommand types

  func testAllFrameCommandTypesCanBeConstructed() {
    let rect = CGRect(x: 0, y: 0, width: 10, height: 10)
    let cmds: [FrameCommand] = [
      .rect(rect, color: 0xFF00_00FF, source: .terminal),
      .glyphRun(
        origin: .zero, text: "A", foreground: 0x0000_00FF, background: 0xFFFF_FFFF,
        source: .terminal),
      .cursor(rect, color: 0x3A4D_53FF),
      .selection(rect, color: 0xECE3_CC80),
      .clip(rect),
      .texturedQuad(rect: rect, resourceId: 42, source: .image),
    ]
    XCTAssertEqual(cmds.count, 6)
  }

  func testTexturedQuadCommandCarriesResourceId() {
    let quad = FrameCommand.texturedQuad(
      rect: CGRect(x: 1, y: 2, width: 16, height: 16),
      resourceId: 99,
      source: .image
    )
    if case .texturedQuad(_, let resourceId, let source) = quad {
      XCTAssertEqual(resourceId, 99)
      XCTAssertEqual(source, .image)
    } else {
      XCTFail("expected texturedQuad")
    }
  }

  func testAllSourceTagsAreRepresented() {
    let sources: [FrameSource] = [.sidebar, .chrome, .terminal, .cursor, .selection, .image]
    XCTAssertEqual(sources.count, 6)
  }

  // MARK: - BitmapSurface

  func testRectCommandChangesPixels() {
    let surface = BitmapSurface(width: 16, height: 16)
    let before = surface.pixel(x: 8, y: 8)!

    let renderer = SoftwareRenderer(surface: surface, fontAtlas: FontAtlas())
    renderer.render([
      .rect(CGRect(x: 0, y: 0, width: 16, height: 16), color: 0xFF00_00FF, source: .terminal)
    ])

    let after = surface.pixel(x: 8, y: 8)!
    XCTAssertNotEqual(before, after, "pixels must change after rect draw")

    let r = (after >> 24) & 0xFF
    let b = (after >> 8) & 0xFF
    XCTAssertGreaterThan(r, 0, "red channel must be present")
    XCTAssertEqual(b, 0, "blue channel must be absent for pure red fill")
  }

  func testRectCommandFillsExpectedRegion() {
    let surface = BitmapSurface(width: 16, height: 16)
    let renderer = SoftwareRenderer(surface: surface, fontAtlas: FontAtlas())
    renderer.render([
      .rect(CGRect(x: 8, y: 8, width: 8, height: 8), color: 0xFF00_00FF, source: .terminal)
    ])

    let inside = surface.pixel(x: 12, y: 12)!
    XCTAssertNotEqual(inside, 0, "pixel inside filled rect must be non-zero")
    let r = (inside >> 24) & 0xFF
    XCTAssertGreaterThan(r, 0, "red channel must be set inside the filled rect")

    let outside = surface.pixel(x: 4, y: 4)!
    XCTAssertEqual(outside, 0, "pixel outside filled rect must remain zero")
  }

  // MARK: - Glyph rendering

  func testGlyphCommandProducesNonBackgroundPixels() {
    let cellW = 10
    let cellH = 18
    let surface = BitmapSurface(width: cellW, height: cellH)
    let fontAtlas = FontAtlas()
    let renderer = SoftwareRenderer(surface: surface, fontAtlas: fontAtlas)

    let bg: UInt32 = Theme.CurrentTheme.bg0
    renderer.render([
      .rect(
        CGRect(x: 0, y: 0, width: CGFloat(cellW), height: CGFloat(cellH)), color: bg,
        source: .terminal),
      .glyphRun(
        origin: .zero, text: "A", foreground: Theme.CurrentTheme.fg1, background: bg,
        source: .terminal),
    ])

    var foundNonBg = false
    for y in 0..<cellH {
      for x in 0..<cellW {
        if let p = surface.pixel(x: x, y: y), p != bg {
          foundNonBg = true
          break
        }
      }
      if foundNonBg { break }
    }
    XCTAssertTrue(foundNonBg, "glyph draw must produce at least one non-background pixel")
  }

  // MARK: - PNG encoding

  func testPNGBytesHaveValidSignature() {
    let surface = BitmapSurface(width: 4, height: 4)
    let renderer = SoftwareRenderer(surface: surface, fontAtlas: FontAtlas())
    renderer.render([
      .rect(CGRect(x: 0, y: 0, width: 4, height: 4), color: 0x1234_56FF, source: .terminal)
    ])

    guard let data = surface.pngData else {
      XCTFail("pngData must not be nil after rendering")
      return
    }
    XCTAssertGreaterThan(data.count, 8)

    let expected: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    let actual = [UInt8](data.prefix(8))
    XCTAssertEqual(actual, expected, "PNG magic bytes must match RFC 2083 signature")
  }

  func testPNGFromClearSurfaceIsNonEmpty() {
    let surface = BitmapSurface(width: 80, height: 24)
    SoftwareRenderer(surface: surface, fontAtlas: FontAtlas()).render([
      .rect(
        CGRect(x: 0, y: 0, width: 80, height: 24), color: Theme.CurrentTheme.bg0,
        source: .terminal)
    ])
    guard let data = surface.pngData else {
      XCTFail("pngData must not be nil")
      return
    }
    XCTAssertGreaterThan(data.count, 100, "PNG must contain image data beyond the header")
  }

  // MARK: - Backing-scale surface and renderer

  func testBitmapSurfaceLogicalSizeHelpers() {
    let surface = BitmapSurface(width: 40, height: 20, scale: 2)
    XCTAssertEqual(surface.scale, 2)
    XCTAssertEqual(surface.logicalWidth, 20)
    XCTAssertEqual(surface.logicalHeight, 10)
    XCTAssertEqual(surface.logicalSize, CGSize(width: 20, height: 10))
  }

  func testScaledRectPaintsCorrectPhysicalPixels() {
    // 20x20 physical pixels at scale 2 = 10x10 logical area
    let surface = BitmapSurface(width: 20, height: 20, scale: 2)
    let renderer = SoftwareRenderer(surface: surface, fontAtlas: FontAtlas())
    // Draw a 4x4 logical rect starting at (2, 2) → physical pixels 4..11 in both axes
    renderer.render([
      .rect(CGRect(x: 2, y: 2, width: 4, height: 4), color: 0xFF00_00FF, source: .terminal)
    ])
    // Physical pixel inside the rect must be painted
    let inside = surface.pixel(x: 6, y: 6)!
    XCTAssertNotEqual(inside, 0, "physical pixel inside scaled rect must be painted")
    let r = (inside >> 24) & 0xFF
    XCTAssertGreaterThan(r, 0, "red channel must be set for the red fill")
    // Physical pixel outside the painted region must remain zero
    let outside = surface.pixel(x: 1, y: 1)!
    XCTAssertEqual(outside, 0, "physical pixel outside scaled rect must stay zero")
  }

  func testScaledGlyphProducesNonBackgroundPixels() {
    // 20x36 physical pixels at scale 2 = 10x18 logical area
    let surface = BitmapSurface(width: 20, height: 36, scale: 2)
    let fontAtlas = FontAtlas()
    let renderer = SoftwareRenderer(surface: surface, fontAtlas: fontAtlas)
    let bg: UInt32 = Theme.CurrentTheme.bg0
    renderer.render([
      .rect(CGRect(x: 0, y: 0, width: 10, height: 18), color: bg, source: .terminal),
      .glyphRun(
        origin: .zero, text: "A", foreground: Theme.CurrentTheme.fg1, background: bg,
        source: .terminal),
    ])
    var foundNonBg = false
    for y in 0..<36 {
      for x in 0..<20 {
        if let p = surface.pixel(x: x, y: y), p != bg {
          foundNonBg = true
          break
        }
      }
      if foundNonBg { break }
    }
    XCTAssertTrue(
      foundNonBg, "scaled glyph must produce at least one non-background physical pixel")
  }

  // MARK: - Block-element geometry (BoxDrawing)

  func testBoxDrawingFullBlockEmitsCellSizedRect() {
    // █ U+2588 must produce one rect that exactly covers the cell. Adjacent
    // full blocks then tile gap-free because consecutive cells' rects share
    // an integer pixel boundary.
    let rects = BoxDrawing.blockElementRects(
      Unicode.Scalar(0x2588)!,
      at: CGPoint(x: 0, y: 0),
      cellWidth: 8, cellHeight: 18,
      foreground: 0xFF00_00FF
    )
    XCTAssertEqual(rects.count, 1)
    XCTAssertEqual(rects[0].rect, CGRect(x: 0, y: 0, width: 8, height: 18))
    XCTAssertEqual(rects[0].color, 0xFF00_00FF)
  }

  func testBoxDrawingFullBlockCoversOddCellHeightExactly() {
    // The full block must paint every pixel of the cell even when the cell
    // height is odd — that's the gap-tiling guarantee.
    let rects = BoxDrawing.blockElementRects(
      Unicode.Scalar(0x2588)!,
      at: .zero, cellWidth: 8, cellHeight: 17,
      foreground: 0xFF
    )
    XCTAssertEqual(rects.count, 1)
    XCTAssertEqual(rects[0].rect, CGRect(x: 0, y: 0, width: 8, height: 17))
  }

  func testBoxDrawingQuadrantUpperLeftEmitsTopLeftRect() {
    let rects = BoxDrawing.blockElementRects(
      Unicode.Scalar(0x2598)!,  // ▘
      at: CGPoint(x: 0, y: 0),
      cellWidth: 8, cellHeight: 18,
      foreground: 0xFF00_00FF
    )
    XCTAssertEqual(rects.count, 1)
    // CG y=0 is bottom; top-left quadrant is at y >= bottomH (= 9).
    XCTAssertEqual(rects[0].rect, CGRect(x: 0, y: 9, width: 4, height: 9))
  }

  // MARK: - Cursor and selection

  func testCursorCommandFillsCell() {
    let surface = BitmapSurface(width: 10, height: 18)
    let renderer = SoftwareRenderer(surface: surface, fontAtlas: FontAtlas())
    renderer.render([
      .rect(
        CGRect(x: 0, y: 0, width: 10, height: 18), color: Theme.CurrentTheme.bg0,
        source: .terminal),
      .cursor(CGRect(x: 0, y: 0, width: 10, height: 18), color: Theme.CurrentTheme.cursor),
    ])
    let p = surface.pixel(x: 5, y: 9)!
    XCTAssertNotEqual(p, Theme.CurrentTheme.bg0, "cursor must overdraw background")
  }

  // MARK: - Smoke: large grid (diagnostic, not a gate)

  func testLargeGridSmokeDiagnostic() {
    let cols = 220
    let rows = 50
    let cellW = 8
    let cellH = 16
    let width = cols * cellW
    let height = rows * cellH

    let surface = BitmapSurface(width: width, height: height)
    let fontAtlas = FontAtlas()
    let renderer = SoftwareRenderer(surface: surface, fontAtlas: fontAtlas)

    var cmds: [FrameCommand] = []
    cmds.append(
      .rect(
        CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)),
        color: Theme.CurrentTheme.bg0, source: .terminal))
    let glyphs = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!@#$%^&*()")
    for row in 0..<rows {
      for col in 0..<cols {
        let x = CGFloat(col * cellW)
        let y = CGFloat((rows - 1 - row) * cellH)
        let ch = String(glyphs[(row * cols + col) % glyphs.count])
        cmds.append(
          .glyphRun(
            origin: CGPoint(x: x, y: y),
            text: ch,
            foreground: Theme.CurrentTheme.fg1,
            background: Theme.CurrentTheme.bg0,
            source: .terminal
          ))
      }
    }

    let start = Date()
    renderer.render(cmds)
    let elapsed = Date().timeIntervalSince(start)

    print(
      "[smoke] large-grid: \(cmds.count) commands, \(String(format: "%.1f", elapsed * 1000))ms, \(cols)x\(rows) cells"
    )
    XCTAssertEqual(cmds.count, 1 + rows * cols, "command count must match expected size")
    XCTAssertNotNil(surface.pngData, "large grid surface must encode to PNG")
  }
}
