import Foundation
import LabanCore
import XCTest

// Direct coverage for the display-width helper that maps Unicode scalars to
// terminal column advance. Laban runs libghostty with DEC mode 2027
// (grapheme_cluster) DISABLED, so width is summed per scalar — these cases pin
// that contract so scrollback find/copy and IME preedit stay column-aligned.
final class TerminalDisplayWidthTests: XCTestCase {

  func testAsciiIsNarrow() {
    XCTAssertFalse(TerminalDisplayWidth.isWide("A"))
    XCTAssertEqual(TerminalDisplayWidth.cells(of: "A"), 1)
    XCTAssertEqual(TerminalDisplayWidth.cells(of: "hello"), 5)
  }

  func testCJKIsWide() {
    // U+4E2D 中 — canonical wide CJK ideograph.
    let mid = Unicode.Scalar(0x4E2D)!
    XCTAssertTrue(TerminalDisplayWidth.isWide(mid))
    XCTAssertEqual(TerminalDisplayWidth.cells(of: "\u{4E2D}"), 2)
  }

  func testCombiningMarkIsZeroWidth() {
    // "e" + U+0301 COMBINING ACUTE ACCENT → one base column, mark adds nothing.
    XCTAssertEqual(TerminalDisplayWidth.cells(of: "e\u{0301}"), 1)
  }

  func testVS16IsZeroWidth() {
    // U+2764 HEAVY BLACK HEART is narrow; U+FE0F VARIATION SELECTOR-16 adds no
    // column under mode-2027-disabled per-scalar accounting → total 1.
    XCTAssertFalse(TerminalDisplayWidth.isWide(Unicode.Scalar(0xFE0F)!))
    XCTAssertEqual(TerminalDisplayWidth.cells(of: "\u{2764}\u{FE0F}"), 1)
  }

  func testZWJEmojiSequenceSumsPerScalar() {
    // 👩‍💻 = U+1F469 (wide 2) + U+200D ZWJ (zero) + U+1F4BB (wide 2) = 4,
    // because mode 2027 is disabled: each scalar contributes independently.
    XCTAssertEqual(TerminalDisplayWidth.cells(of: "\u{1F469}\u{200D}\u{1F4BB}"), 4)
  }

  func testRegionalIndicatorFlagPairSumsPerScalar() {
    // 🇸🇪 = U+1F1F8 + U+1F1EA, two wide regional indicators → 2 + 2 = 4.
    XCTAssertTrue(TerminalDisplayWidth.isWide(Unicode.Scalar(0x1F1F8)!))
    XCTAssertEqual(TerminalDisplayWidth.cells(of: "\u{1F1F8}\u{1F1EA}"), 4)
  }

  func testSkinToneModifierSumsPerScalar() {
    // 👋🏽 = U+1F44B (wide 2) + U+1F3FD skin-tone modifier (wide 2) → 4.
    XCTAssertEqual(TerminalDisplayWidth.cells(of: "\u{1F44B}\u{1F3FD}"), 4)
  }

  func testTwoEmAndThreeEmDashAreWide() {
    // Regression: U+2E3A TWO-EM DASH and U+2E3B THREE-EM DASH sit just below the
    // 0x2E80 wide block but libghostty renders them width 2. They must not fall
    // back to width 1 (a 2-codepoint column off-by-one in find/copy/preedit).
    XCTAssertTrue(TerminalDisplayWidth.isWide(Unicode.Scalar(0x2E3A)!))
    XCTAssertTrue(TerminalDisplayWidth.isWide(Unicode.Scalar(0x2E3B)!))
    XCTAssertEqual(TerminalDisplayWidth.cells(of: "\u{2E3A}"), 2)
    XCTAssertEqual(TerminalDisplayWidth.cells(of: "\u{2E3B}"), 2)
    // Boundary guard: the surrounding scalars stay narrow (only these two widen).
    XCTAssertFalse(TerminalDisplayWidth.isWide(Unicode.Scalar(0x2E39)!))
    XCTAssertFalse(TerminalDisplayWidth.isWide(Unicode.Scalar(0x2E3C)!))
  }
}
