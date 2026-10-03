import XCTest

@testable import LabanCore

final class TerminalBidiTests: XCTestCase {
  private func cells(_ text: String) -> [TerminalBidi.Cell] {
    text.enumerated().map {
      TerminalBidi.Cell(column: $0.offset, width: 1, text: String($0.element))
    }
  }

  func testLeftToRightRowNeedsNoLayout() {
    XCTAssertNil(TerminalBidi.layout(cells: cells("hello world"), columns: 20))
  }

  func testHebrewRunIsMirroredBetweenLeftToRightText() throws {
    // "ab שלום cd": columns 0-1 ab, 2 space, 3-6 Hebrew, 7 space, 8-9 cd.
    let layout = try XCTUnwrap(
      TerminalBidi.layout(cells: cells("ab \u{05E9}\u{05DC}\u{05D5}\u{05DD} cd"), columns: 12))
    XCTAssertEqual(Array(layout.visualColumn[0...2]), [0, 1, 2])
    XCTAssertEqual(Array(layout.visualColumn[3...6]), [6, 5, 4, 3], "Hebrew reads right to left")
    XCTAssertEqual(Array(layout.visualColumn[7...9]), [7, 8, 9])
    XCTAssertEqual(Array(layout.isRightToLeft[3...6]), [true, true, true, true])
    XCTAssertFalse(layout.isRightToLeft[0])
    XCTAssertEqual(layout.visualColumn[11], 11, "columns past the content stay put")
    for logical in 0..<12 {
      XCTAssertEqual(layout.logicalColumn[layout.visualColumn[logical]], logical)
    }
  }

  func testDigitsInsideArabicKeepLeftToRightOrder() throws {
    // "سلام 12": Arabic at 0-3, space 4, digits 5-6. Visual: digits keep
    // their own order inside the right-to-left embedding.
    let layout = try XCTUnwrap(
      TerminalBidi.layout(cells: cells("\u{0633}\u{0644}\u{0627}\u{0645} 12"), columns: 7))
    let one = layout.visualColumn[5]
    let two = layout.visualColumn[6]
    XCTAssertEqual(two, one + 1, "1 is drawn left of 2")
    XCTAssertGreaterThan(layout.visualColumn[0], layout.visualColumn[3], "Arabic is mirrored")
  }
}
