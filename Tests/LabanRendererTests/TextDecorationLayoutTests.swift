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

  /// With the font's underline metrics the line sits where the font puts
  /// it, snapped to device pixels, between the cell bottom and the baseline;
  /// a double underline's second line goes below the first.
  func testLayoutUsesFontUnderlineMetricsWhenSupplied() throws {
    let origin = CGPoint(x: 0, y: 40)
    let descent: CGFloat = 5
    let layout = try XCTUnwrap(
      TextDecorationLayout.make(
        origin: origin, cellCount: 2, attributes: [.underline], underlineStyle: .single,
        cellAdvance: 10, cellHeight: 20, descent: descent, scale: 2,
        underlineMetrics: (position: -1.3, thickness: 0.8)))
    XCTAssertEqual(layout.thickness, 1, "0.8pt rounds to 2 device pixels at 2x")
    let rect = try XCTUnwrap(layout.underlineRects.first)
    // Top at baseline - 1.3 = 43.7, minus thickness = 42.7, snapped down to 42.5.
    XCTAssertEqual(rect.minY, 42.5)
    XCTAssertLessThanOrEqual(rect.maxY, origin.y + descent, "the line stays below the baseline")

    let double = try XCTUnwrap(
      TextDecorationLayout.make(
        origin: origin, cellCount: 2, attributes: [], underlineStyle: .double,
        cellAdvance: 10, cellHeight: 20, descent: descent, scale: 2,
        underlineMetrics: (position: -1.3, thickness: 0.8)))
    XCTAssertEqual(double.underlineRects.count, 2)
    XCTAssertLessThan(double.underlineRects[1].minY, double.underlineRects[0].minY)
    XCTAssertGreaterThanOrEqual(double.underlineRects[1].minY, origin.y)

    let clamped = try XCTUnwrap(
      TextDecorationLayout.make(
        origin: origin, cellCount: 1, attributes: [.underline], underlineStyle: .single,
        cellAdvance: 10, cellHeight: 20, descent: descent, scale: 2,
        underlineMetrics: (position: -40, thickness: 1)))
    XCTAssertEqual(clamped.underlineRects.first?.minY, origin.y, "never below the cell")
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

  func testDashedUnderlinePhaseContinuesAcrossAdjacentRuns() throws {
    func dashOrigins(_ layout: TextDecorationLayout?) -> [CGFloat] {
      (layout?.underlineRects ?? []).map { $0.minX }
    }
    // One continuous dashed underline spanning 4 cells, split into two
    // adjacent 2-cell style runs (e.g. a mid-span foreground/hyperlink change).
    // The second run must continue the dash phase from the shared row origin
    // (x = 0), not restart the pattern at its own left edge.
    let runA = TextDecorationLayout.make(
      origin: CGPoint(x: 0, y: 0), cellCount: 2, attributes: [],
      underlineStyle: .dashed, cellAdvance: 10, cellHeight: 18, descent: 4, scale: 1,
      phaseOriginX: 0)
    let runB = TextDecorationLayout.make(
      origin: CGPoint(x: 20, y: 0), cellCount: 2, attributes: [],
      underlineStyle: .dashed, cellAdvance: 10, cellHeight: 18, descent: 4, scale: 1,
      phaseOriginX: 0)
    let whole = TextDecorationLayout.make(
      origin: CGPoint(x: 0, y: 0), cellCount: 4, attributes: [],
      underlineStyle: .dashed, cellAdvance: 10, cellHeight: 18, descent: 4, scale: 1,
      phaseOriginX: 0)

    XCTAssertEqual(dashOrigins(runA) + dashOrigins(runB), dashOrigins(whole))
  }
}
