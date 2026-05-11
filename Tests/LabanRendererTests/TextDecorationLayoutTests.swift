import CoreGraphics
import XCTest

@testable import LabanRenderer

final class TextDecorationLayoutTests: XCTestCase {
  func testLayoutUsesSuppliedGlyphRunMetrics() {
    let layout = TextDecorationLayout.make(
      origin: CGPoint(x: 5, y: 7),
      cellCount: 3,
      attributes: [.underline, .strikethrough, .overline],
      underlineStyle: .single,
      cellAdvance: 11,
      cellHeight: 17,
      descent: 6,
      scale: 2)

    XCTAssertEqual(layout?.thickness, 1)
    XCTAssertEqual(layout?.underlineRects, [CGRect(x: 5, y: 9, width: 33, height: 1)])
    XCTAssertEqual(layout?.strikethroughRect, CGRect(x: 5, y: 15, width: 33, height: 1))
    XCTAssertEqual(layout?.overlineRect, CGRect(x: 5, y: 22, width: 33, height: 1))
  }

  func testCurlyUnderlineUsesSharedPointPath() throws {
    let layout = try XCTUnwrap(
      TextDecorationLayout.make(
        origin: .zero,
        cellCount: 2,
        attributes: [],
        underlineStyle: .curly,
        cellAdvance: 10,
        cellHeight: 18,
        descent: 4,
        scale: 1))

    XCTAssertTrue(layout.underlineRects.isEmpty)
    XCTAssertGreaterThan(layout.curlyUnderlinePoints.count, 2)
    XCTAssertEqual(layout.curlyUnderlinePoints.first?.x, 0)
    XCTAssertEqual(layout.curlyUnderlinePoints.last?.x, 20)
  }
}
