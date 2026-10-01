import CoreText
import Foundation
import XCTest

@testable import LabanRenderer

final class TerminalLigatureShaperTests: XCTestCase {
  /// The bundled JetBrains Mono, independent of any user font pick.
  private let font = FontAtlas(pointSize: 14, fontName: nil).font

  func testCandidateGateNeedsAdjacentASCIISymbols() {
    XCTAssertTrue(TerminalLigatureShaper.mayContainLigature("x -> y"))
    XCTAssertTrue(TerminalLigatureShaper.mayContainLigature("a!=b"))
    XCTAssertTrue(TerminalLigatureShaper.mayContainLigature("中 :: 文"))
    XCTAssertFalse(TerminalLigatureShaper.mayContainLigature("hello world"))
    XCTAssertFalse(TerminalLigatureShaper.mayContainLigature("a - > b"))
    XCTAssertFalse(TerminalLigatureShaper.mayContainLigature("fi"))
    XCTAssertFalse(TerminalLigatureShaper.mayContainLigature("-"))
    XCTAssertFalse(TerminalLigatureShaper.mayContainLigature(""))
  }

  func testArrowShapesToSpacerThenLigatureGlyphInSameCells() throws {
    let cells = try XCTUnwrap(TerminalLigatureShaper.shape(text: "x -> y", font: font))
    XCTAssertEqual(cells.count, 6, "one entry per cell")
    XCTAssertEqual(cells[0], .nominal)
    XCTAssertEqual(cells[1], .nominal)
    XCTAssertEqual(cells[4], .nominal)
    XCTAssertEqual(cells[5], .nominal)
    guard case .glyph(let spacer) = cells[2], case .glyph(let ligature) = cells[3] else {
      return XCTFail("expected substituted glyphs for '->', got \(cells)")
    }
    XCTAssertNotEqual(spacer, ligature)
    // The joined arrow reaches back over the spacer cell: negative left
    // bearing of roughly one advance.
    var glyph = ligature
    let bounds = CTFontGetBoundingRectsForGlyphs(font, .horizontal, &glyph, nil, 1)
    var advance = CGSize.zero
    CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)
    XCTAssertLessThan(bounds.minX, -advance.width * 0.5)
  }

  func testTripleEqualsSubstitutesAllThreeCells() throws {
    let cells = try XCTUnwrap(TerminalLigatureShaper.shape(text: "===", font: font))
    XCTAssertEqual(cells.count, 3)
    for cell in cells {
      guard case .glyph = cell else { return XCTFail("expected substitution, got \(cells)") }
    }
  }

  func testPlainTextShapesToNil() {
    XCTAssertNil(TerminalLigatureShaper.shape(text: "abc def", font: font))
    XCTAssertNil(TerminalLigatureShaper.shape(text: "a - > b", font: font))
  }

  func testNonASCIICellsStayNominalAndCellIndexesSurviveMultiUnitCharacters() throws {
    // "é" is one cell but its decomposed form is two UTF-16 units; the arrow
    // after it must still map onto cells 2 and 3.
    let text = "e\u{301} ->"
    let cells = try XCTUnwrap(TerminalLigatureShaper.shape(text: text, font: font))
    XCTAssertEqual(cells.count, Array(text).count)
    XCTAssertEqual(cells[0], .nominal)
    XCTAssertEqual(cells[1], .nominal)
    guard case .glyph = cells[2], case .glyph = cells[3] else {
      return XCTFail("arrow must still ligate after a multi-unit cluster, got \(cells)")
    }
  }
}

final class FontLigatureSettingsTests: XCTestCase {
  private var defaults: UserDefaults!
  private let suiteName = "laban-font-ligature-settings-tests-\(getpid())"

  override func setUp() {
    super.setUp()
    defaults = UserDefaults(suiteName: suiteName)
    defaults.removePersistentDomain(forName: suiteName)
  }

  override func tearDown() {
    defaults.removePersistentDomain(forName: suiteName)
    super.tearDown()
  }

  func testDefaultsOff() {
    XCTAssertFalse(FontLigatureSettings.enabled(defaults: defaults, environment: [:]))
  }

  func testSetEnabledPersistsAndNotifies() {
    let exp = expectation(
      forNotification: FontLigatureSettings.didChangeNotification, object: nil, handler: nil)
    XCTAssertTrue(FontLigatureSettings.setEnabled(true, defaults: defaults, environment: [:]))
    wait(for: [exp], timeout: 1.0)
    XCTAssertTrue(FontLigatureSettings.enabled(defaults: defaults, environment: [:]))
  }

  func testEnvironmentOverrideWinsAndLocksWrites() {
    let env = [FontLigatureSettings.enabledEnvironmentKey: "1"]
    XCTAssertTrue(FontLigatureSettings.enabled(defaults: defaults, environment: env))
    XCTAssertFalse(FontLigatureSettings.setEnabled(false, defaults: defaults, environment: env))
    XCTAssertNil(defaults.object(forKey: FontLigatureSettings.enabledKey))
    XCTAssertFalse(
      FontLigatureSettings.enabled(
        defaults: defaults, environment: [FontLigatureSettings.enabledEnvironmentKey: "0"]))
  }
}
