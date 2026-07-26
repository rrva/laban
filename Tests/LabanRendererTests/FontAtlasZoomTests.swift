import XCTest

@testable import LabanRenderer

final class FontAtlasZoomTests: XCTestCase {
  /// A private suite, not `UserDefaults.standard`. Under
  /// `swift test --parallel` every test process shares the one on-disk
  /// preferences domain, so writing `FontAtlas.userFontKey` there races
  /// concurrently running suites that read it. Wiping the suite in
  /// setUp/tearDown also removes the need to save and restore the previous
  /// value by hand. See `execplans/active/test-userdefaults-isolation.md`.
  private var defaults: UserDefaults!
  private let suiteName = "laban-font-atlas-zoom-tests-\(getpid())"

  override func setUp() {
    super.setUp()
    defaults = UserDefaults(suiteName: suiteName)
    defaults.removePersistentDomain(forName: suiteName)
  }

  override func tearDown() {
    defaults.removePersistentDomain(forName: suiteName)
    super.tearDown()
  }

  func testWithPointSizePreservesActiveFontWhenDefaultsChange() throws {
    let active = FontAtlas(pointSize: 14, fontName: "Menlo")
    defaults.set("Helvetica", forKey: FontAtlas.userFontKey)

    let resized = active.withPointSize(20)
    let defaultsResolved = FontAtlas(pointSize: 20, defaults: defaults)
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
