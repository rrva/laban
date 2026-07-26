import CoreGraphics
import Metal
import XCTest

@testable import LabanRenderer

final class GlyphAtlasLadderTests: XCTestCase {

  func testLadderEntryMatchesDirectFontAtlasMetrics() throws {
    guard let device = MTLCreateSystemDefaultDevice() else {
      throw XCTSkip("no Metal device available")
    }
    let ladder = GlyphAtlasLadder(device: device, scale: 2, fontName: nil)
    guard let entry = ladder.makeEntry(forPointSize: 16) else {
      return XCTFail("makeEntry(forPointSize: 16) returned nil")
    }

    let reference = FontAtlas(pointSize: 16)
    XCTAssertEqual(entry.fontAtlas.pointSize, 16)
    XCTAssertEqual(entry.fontAtlas.cellSize.width, reference.cellSize.width)
    XCTAssertEqual(entry.fontAtlas.cellSize.height, reference.cellSize.height)
    XCTAssertEqual(
      entry.sidebarFontAtlas.pointSize,
      FontAtlas.sidebarPointSize(forTerminalPointSize: 16))
  }

  func testPrewarmedEntryServesASCIIWithoutNewRasterization() throws {
    guard let device = MTLCreateSystemDefaultDevice() else {
      throw XCTSkip("no Metal device available")
    }
    let ladder = GlyphAtlasLadder(device: device, scale: 2, fontName: nil)
    guard let entry = ladder.makeEntry(forPointSize: 16) else {
      return XCTFail("makeEntry(forPointSize: 16) returned nil")
    }

    XCTAssertFalse(entry.terminalAtlas.didOverflow)
    let countAfterPrewarm = entry.terminalAtlas.rasterizedGlyphCount
    XCTAssertGreaterThan(countAfterPrewarm, 0, "prewarm must rasterize ASCII")

    // The acceptance bar for the ladder: adopting a prewarmed atlas and then
    // drawing the whole printable ASCII range rasterizes nothing new.
    for value in 0x20...0x7E {
      let scalar = Unicode.Scalar(value)!
      XCTAssertNotNil(
        entry.terminalAtlas.entry(
          scalar: scalar,
          font: entry.fontAtlas.font,
          boldFallback: false,
          italicFallback: false),
        "prewarmed atlas must serve U+\(String(value, radix: 16))")
    }
    XCTAssertEqual(
      entry.terminalAtlas.rasterizedGlyphCount, countAfterPrewarm,
      "ASCII lookups after prewarm must not rasterize")
  }

  func testPrewarmedEntryServesStyledASCIIWithoutNewRasterization() throws {
    guard let device = MTLCreateSystemDefaultDevice() else {
      throw XCTSkip("no Metal device available")
    }
    let ladder = GlyphAtlasLadder(device: device, scale: 2, fontName: nil)
    guard let entry = ladder.makeEntry(forPointSize: 16) else {
      return XCTFail("makeEntry(forPointSize: 16) returned nil")
    }

    let countAfterPrewarm = entry.terminalAtlas.rasterizedGlyphCount
    for bold in [false, true] {
      for italic in [false, true] {
        let variant = entry.fontAtlas.styledFontVariant(bold: bold, italic: italic)
        for value in 0x20...0x7E {
          let scalar = Unicode.Scalar(value)!
          XCTAssertNotNil(
            entry.terminalAtlas.entry(
              scalar: scalar,
              font: variant.font,
              boldFallback: variant.boldFallback,
              italicFallback: variant.italicFallback),
            "prewarmed atlas must serve styled U+\(String(value, radix: 16))")
        }
      }
    }
    XCTAssertEqual(
      entry.terminalAtlas.rasterizedGlyphCount, countAfterPrewarm,
      "styled ASCII lookups after prewarm must not rasterize")
  }

  func testLadderUsesActiveFontWhenDefaultsChangeBeforeZoom() throws {
    guard let device = MTLCreateSystemDefaultDevice() else {
      throw XCTSkip("no Metal device available")
    }
    // A private suite rather than `UserDefaults.standard`: every test process
    // shares the one on-disk preferences domain under `swift test --parallel`,
    // so writing `FontAtlas.userFontKey` there races suites that read it. This
    // test previously failed that way ("10.0" is not equal to "14.0"). Wiping
    // the suite also replaces the manual save/restore. See
    // `execplans/active/test-userdefaults-isolation.md`.
    let suiteName = "laban-glyph-atlas-ladder-tests-\(getpid())"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
      return XCTFail("could not create the isolated defaults suite")
    }
    defaults.removePersistentDomain(forName: suiteName)
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let active = FontAtlas(pointSize: 14, defaults: defaults)
    let activeSidebar = FontAtlas(pointSize: 11, defaults: defaults)
    defaults.set("Helvetica", forKey: FontAtlas.userFontKey)

    let ladder = GlyphAtlasLadder(
      device: device,
      scale: 2,
      fontAtlas: active,
      sidebarFontAtlas: activeSidebar)
    guard let entry = ladder.makeEntry(forPointSize: 20) else {
      return XCTFail("makeEntry(forPointSize: 20) returned nil")
    }

    XCTAssertEqual(entry.fontAtlas.fontPostScriptName, active.fontPostScriptName)
    XCTAssertNotEqual(
      entry.fontAtlas.fontPostScriptName,
      FontAtlas(pointSize: 20, defaults: defaults).fontPostScriptName)
  }

  func testFullLadderBuildsAllSizesWithinMemoryBudget() throws {
    guard let device = MTLCreateSystemDefaultDevice() else {
      throw XCTSkip("no Metal device available")
    }
    let activeSize = Int(FontAtlas.defaultTerminalPointSize)
    let ladder = GlyphAtlasLadder(device: device, scale: 2, fontName: nil)
    ladder.prebuild(excluding: activeSize)

    let lo = Int(FontAtlas.zoomMinimumPointSize)
    let hi = Int(FontAtlas.zoomMaximumPointSize)
    for size in lo...hi {
      let entry = try XCTUnwrap(
        ladder.entry(forPointSize: size),
        "missing ladder entry for \(size) pt")
      XCTAssertFalse(entry.terminalAtlas.didOverflow, "terminal atlas overflowed at \(size) pt")
      XCTAssertFalse(entry.sidebarAtlas.didOverflow, "sidebar atlas overflowed at \(size) pt")
    }

    let budget = 48 * 1024 * 1024
    let megabytes = Double(ladder.totalTextureBytes) / (1024 * 1024)
    print(String(format: "[ladder] full 8…40 ladder at 2x scale: %.1f MB", megabytes))
    XCTAssertLessThanOrEqual(
      ladder.totalTextureBytes, budget,
      "ladder texture memory exceeds the 48 MB budget at 2x scale")
  }
}
