import CoreGraphics
import XCTest

@testable import LabanRenderer

final class BoxDrawingProceduralTests: XCTestCase {
  private func rects(_ scalar: Unicode.Scalar, w: CGFloat = 9, h: CGFloat = 19) -> [CGRect] {
    BoxDrawing.proceduralCellElementRects(
      scalar, at: .zero, cellWidth: w, cellHeight: h, foreground: 0xFFFF_FFFF
    ).map(\.rect)
  }

  private func covers(_ rects: [CGRect], _ point: CGPoint) -> Bool {
    rects.contains { $0.contains(point) }
  }

  func testStraightLinesAreProceduralButDoubleArcsAndDiagonalsAreNot() {
    for value: UInt32 in [0x2500, 0x2501, 0x2502, 0x253C, 0x254B, 0x2504, 0x2574, 0x257F] {
      XCTAssertTrue(BoxDrawing.isProceduralCellElement(Unicode.Scalar(value)!), "U+\(value)")
    }
    for value: UInt32 in [0x2550, 0x256C, 0x256D, 0x2571, 0x2573] {
      XCTAssertFalse(BoxDrawing.isBoxLine(Unicode.Scalar(value)!), "U+\(value)")
    }
  }

  func testLinesReachEveryCellEdgeTheyPointTo() {
    let w: CGFloat = 9
    let h: CGFloat = 19
    let cross = rects("┼", w: w, h: h)
    let midX = (w / 2).rounded(.down)
    let midY = (h / 2).rounded(.down)
    XCTAssertTrue(covers(cross, CGPoint(x: midX, y: 0.5)), "down arm reaches the bottom edge")
    XCTAssertTrue(covers(cross, CGPoint(x: midX, y: h - 0.5)), "up arm reaches the top edge")
    XCTAssertTrue(covers(cross, CGPoint(x: 0.5, y: midY)), "left arm reaches the left edge")
    XCTAssertTrue(covers(cross, CGPoint(x: w - 0.5, y: midY)), "right arm reaches the right edge")

    let corner = rects("┌", w: w, h: h)
    XCTAssertFalse(covers(corner, CGPoint(x: 0.5, y: midY)), "┌ has no left arm")
    XCTAssertFalse(covers(corner, CGPoint(x: midX, y: h - 0.5)), "┌ has no up arm")
    XCTAssertTrue(covers(corner, CGPoint(x: w - 0.5, y: midY)))
    XCTAssertTrue(covers(corner, CGPoint(x: midX, y: 0.5)))
  }

  func testHeavyStrokeIsTwiceTheLightStroke() {
    let light = rects("─")
    let heavy = rects("━")
    XCTAssertEqual(light.map(\.height).max()! * 2, heavy.map(\.height).max()!)
  }

  func testStrokesUseWholePoints() {
    for scalar in "─━│┃┼╋┄┅╌╍╴╺".unicodeScalars {
      for rect in rects(scalar) {
        for edge in [rect.minX, rect.minY, rect.maxX, rect.maxY] {
          XCTAssertEqual(
            edge, edge.rounded(), "U+\(scalar.value) edge \(edge) must be whole points")
        }
      }
    }
  }

  func testBrailleDrawsOneDotPerSetBit() {
    XCTAssertEqual(rects("\u{2800}").count, 0)
    XCTAssertEqual(rects("\u{28FF}").count, 8)
    XCTAssertEqual(rects("\u{2801}").count, 1)
    let topLeft = rects("\u{2801}")[0]
    XCTAssertLessThan(topLeft.midX, 9 / 2, "dot 1 is in the left column")
    XCTAssertGreaterThan(topLeft.midY, 19 * 3 / 4, "dot 1 is in the top row")
  }

  func testSextantsSkipTheHalfBlockPatterns() {
    XCTAssertEqual(rects("\u{1FB00}").count, 1, "U+1FB00 is sextant 1 only")
    XCTAssertEqual(rects("\u{1FB13}").count, 2, "U+1FB13 is pattern 20: sextants 3 and 5")
    // U+1FB14 is pattern 22 because pattern 21 (the left column) is U+258C.
    let pattern22 = rects("\u{1FB14}")
    XCTAssertEqual(pattern22.count, 3)
    XCTAssertEqual(rects("\u{1FB3B}").count, 5, "U+1FB3B is pattern 62")
  }
}
