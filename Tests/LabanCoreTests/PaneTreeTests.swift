import Foundation
import XCTest

@testable import LabanCore

final class PaneTreeTests: XCTestCase {
  let first = PaneTree.leaf(sessionId: "left")
  var split: PaneTree { first.splitting(leaf: "left", axis: .vertical, newSessionId: "right")! }

  func testSplitLeafOrdersSessions() {
    XCTAssertEqual(split.leafSessionIds(), ["left", "right"])
  }
  func testSplitUnknownLeafReturnsNil() {
    XCTAssertNil(split.splitting(leaf: "missing", axis: .vertical, newSessionId: "third"))
  }
  func testRemoveLeafCollapsesToSurvivor() {
    XCTAssertEqual(split.removing(leaf: "left"), .leaf(sessionId: "right"))
    XCTAssertEqual(split.removing(leaf: "right"), first)
  }
  func testRemoveOnlyLeafReturnsNil() { XCTAssertNil(first.removing(leaf: "left")) }
  func testPixelAlignedLayout() {
    let rect = CGRect(x: 0, y: 0, width: 1000, height: 600)
    XCTAssertEqual(
      split.layout(in: rect).map(\.rect),
      [
        CGRect(x: 0, y: 0, width: 500, height: 600),
        CGRect(x: 501, y: 0, width: 499, height: 600),
      ])
    XCTAssertEqual(split.dividerRects(in: rect), [CGRect(x: 500, y: 0, width: 1, height: 600)])
  }
  func testFractionClamped() {
    let changed = split.settingFraction(ofSplitContaining: "right", to: 2)
    XCTAssertEqual(changed.layout(in: CGRect(x: 0, y: 0, width: 100, height: 20))[0].rect.width, 90)
  }
  func testCodableRoundTrip() throws {
    for tree in [
      first, split, first.splitting(leaf: "left", axis: .horizontal, newSessionId: "bottom")!,
    ] {
      XCTAssertEqual(
        try JSONDecoder().decode(PaneTree.self, from: JSONEncoder().encode(tree)), tree)
    }
  }
  func testUnknownShapeThrows() {
    XCTAssertThrowsError(
      try JSONDecoder().decode(PaneTree.self, from: Data(#"{"unknown":{}}"#.utf8)))
  }
  func testDuplicateSessionCannotBeSplitIn() {
    XCTAssertNil(split.splitting(leaf: "left", axis: .vertical, newSessionId: "right"))
  }
}
