import XCTest

@testable import LabanRenderer

final class FontAtlasZoomTests: XCTestCase {
  func testWithPointSizePreservesActiveFontWhenDefaultsChange() throws {
    let defaults = UserDefaults.standard
    let previousFont = defaults.object(forKey: FontAtlas.userFontKey)
    let active = FontAtlas(pointSize: 14, fontName: "Menlo")
    defaults.set("Helvetica", forKey: FontAtlas.userFontKey)
    defer {
      if let previousFont {
        defaults.set(previousFont, forKey: FontAtlas.userFontKey)
      } else {
        defaults.removeObject(forKey: FontAtlas.userFontKey)
      }
    }

    let resized = active.withPointSize(20)
    let defaultsResolved = FontAtlas(pointSize: 20)
    guard defaultsResolved.fontPostScriptName != active.fontPostScriptName else {
      throw XCTSkip("probe fonts resolved to the same PostScript name")
    }

    XCTAssertEqual(resized.pointSize, 20)
    XCTAssertEqual(resized.fontPostScriptName, active.fontPostScriptName)
    XCTAssertNotEqual(resized.fontPostScriptName, defaultsResolved.fontPostScriptName)
  }

  func testMatchesFontNameUsesResolvedPostScriptName() {
    let atlas = FontAtlas(pointSize: 14, fontName: "Menlo")

    XCTAssertTrue(atlas.matches(fontName: "Menlo"))
    XCTAssertFalse(atlas.matches(fontName: "Helvetica"))
    XCTAssertFalse(atlas.matches(fontName: nil))
  }
}
