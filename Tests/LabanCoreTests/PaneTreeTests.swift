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
    XCTAssertEqual(changed.layout(in: CGRect(x: 0, y: 0, width: 100, height: 20))[0].rect.width, 95)
    let low = split.settingFraction(ofSplitContaining: "left", to: -1)
    XCTAssertEqual(low.layout(in: CGRect(x: 0, y: 0, width: 100, height: 20))[0].rect.width, 5)
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

  // MARK: Nested geometry

  /// `A | (B / C)`.
  var leftAndStackedRight: PaneTree {
    split.splitting(leaf: "right", axis: .horizontal, newSessionId: "C")!
  }
  /// `A | ((B / C) | D)`.
  var stackedBetweenColumns: PaneTree {
    .split(
      axis: .vertical, fraction: 0.5, first: .leaf(sessionId: "left"),
      second: .split(
        axis: .vertical, fraction: 0.5,
        first: .split(
          axis: .horizontal, fraction: 0.5, first: .leaf(sessionId: "right"),
          second: .leaf(sessionId: "C")),
        second: .leaf(sessionId: "D")))
  }
  func rect(_ tree: PaneTree, _ id: String, in area: CGRect) -> CGRect {
    tree.layout(in: area).first { $0.sessionId == id }!.rect
  }

  func testDividersCarryPathsInNestedTree() {
    let area = CGRect(x: 0, y: 0, width: 1000, height: 600)
    let dividers = leftAndStackedRight.dividers(in: area)
    XCTAssertEqual(dividers.map(\.path), [[], [.second]])
    XCTAssertEqual(dividers.map(\.axis), [.vertical, .horizontal])
    XCTAssertEqual(dividers[0].container, area)
    XCTAssertEqual(dividers[1].container, CGRect(x: 501, y: 0, width: 499, height: 600))
    // y grows upward: the first (top) child owns the high-y end of its container.
    XCTAssertEqual(dividers[1].rect, CGRect(x: 501, y: 299, width: 499, height: 1))
    XCTAssertEqual(dividers.map(\.fraction), [0.5, 0.5])
    XCTAssertEqual(leftAndStackedRight.dividerRects(in: area), dividers.map(\.rect))
  }

  func testSettingFractionByPath() throws {
    let area = CGRect(x: 0, y: 0, width: 1000, height: 600)
    let changed = try XCTUnwrap(leftAndStackedRight.settingFraction(at: [.second], to: 0.25))
    XCTAssertEqual(rect(changed, "C", in: area), CGRect(x: 501, y: 0, width: 499, height: 449))
    XCTAssertEqual(rect(changed, "right", in: area).height, 150)
    XCTAssertEqual(rect(changed, "left", in: area).width, 500)
    let root = try XCTUnwrap(leftAndStackedRight.settingFraction(at: [], to: 0.3))
    XCTAssertEqual(rect(root, "left", in: area).width, 300)
    XCTAssertEqual(
      try XCTUnwrap(root.settingFraction(at: [], to: .nan)), root, "non-finite is a no-op")
  }

  func testSettingFractionAtLeafPathReturnsNil() {
    XCTAssertNil(leftAndStackedRight.settingFraction(at: [.first], to: 0.3))
    XCTAssertNil(leftAndStackedRight.settingFraction(at: [.second, .first], to: 0.3))
    XCTAssertNil(first.settingFraction(at: [], to: 0.3))
  }

  func testPathToLeaf() {
    let tree = leftAndStackedRight
    XCTAssertEqual(tree.path(toLeaf: "left"), [.first])
    XCTAssertEqual(tree.path(toLeaf: "C"), [.second, .second])
    XCTAssertEqual(first.path(toLeaf: "left"), [])
    XCTAssertNil(tree.path(toLeaf: "missing"))
  }

  func testEqualizeGivesThreeColumnsOneThirdEach() {
    let tree = split.splitting(leaf: "right", axis: .vertical, newSessionId: "C")!
      .settingFraction(at: [], to: 0.8)!
    let area = CGRect(x: 0, y: 0, width: 1000, height: 600)
    for pane in tree.equalized().layout(in: area) {
      XCTAssertEqual(pane.rect.width, 333, accuracy: 1, pane.sessionId)
    }
  }

  func testEqualizeMixedAxisTreatsOtherAxisAsOne() throws {
    let tree = try XCTUnwrap(
      leftAndStackedRight.settingFraction(at: [], to: 0.2)?.settingFraction(at: [.second], to: 0.7))
    let equal = tree.equalized()
    guard case .split(_, let rootFraction, _, let second) = equal,
      case .split(_, let innerFraction, _, _) = second
    else { return XCTFail("shape") }
    XCTAssertEqual(rootFraction, 0.5)
    XCTAssertEqual(innerFraction, 0.5)
  }

  func testDirectionalNeighbourPrefersAdjacentOverWiderOverlap() {
    let area = CGRect(x: 0, y: 0, width: 1000, height: 600)
    let neighbour = stackedBetweenColumns.directionalNeighbour(
      of: "left", direction: .right, in: area, dividerWidth: 1, history: [])
    XCTAssertTrue(["right", "C"].contains(neighbour), "got \(String(describing: neighbour))")
    XCTAssertNotEqual(neighbour, "D")
  }

  func testDirectionalNeighbourUsesHistoryOnTie() {
    let area = CGRect(x: 0, y: 0, width: 1000, height: 601)
    let tree = leftAndStackedRight
    XCTAssertEqual(
      tree.directionalNeighbour(
        of: "left", direction: .right, in: area, dividerWidth: 1, history: ["C", "left"]), "C")
    XCTAssertEqual(
      tree.directionalNeighbour(
        of: "left", direction: .right, in: area, dividerWidth: 1, history: ["right", "left"]),
      "right")
  }

  func testDirectionalNeighbourVerticalAndOtherDirections() {
    let area = CGRect(x: 0, y: 0, width: 1000, height: 601)
    let tree = leftAndStackedRight
    func go(_ id: String, _ d: PaneDirection) -> String? {
      tree.directionalNeighbour(of: id, direction: d, in: area, dividerWidth: 1, history: [])
    }
    XCTAssertEqual(go("right", .down), "C")
    XCTAssertEqual(go("C", .up), "right")
    XCTAssertEqual(go("C", .left), "left")
    XCTAssertEqual(go("right", .left), "left")
    XCTAssertNil(go("right", .up))
    XCTAssertNil(go("C", .down))
  }

  func testDirectionalNeighbourAtEdgeIsNil() {
    let area = CGRect(x: 0, y: 0, width: 1000, height: 600)
    let tree = leftAndStackedRight
    XCTAssertNil(
      tree.directionalNeighbour(
        of: "left", direction: .left, in: area, dividerWidth: 1, history: []))
    XCTAssertNil(
      tree.directionalNeighbour(of: "left", direction: .up, in: area, dividerWidth: 1, history: []))
    XCTAssertNil(
      tree.directionalNeighbour(
        of: "missing", direction: .right, in: area, dividerWidth: 1, history: []))
    XCTAssertNil(
      first.directionalNeighbour(
        of: "left", direction: .right, in: area, dividerWidth: 1, history: []))
  }

  func testMinimumExtentSumsAlongAxisAndMaxesAcross() {
    let tree = stackedBetweenColumns  // A | ((B / C) | D)
    XCTAssertEqual(tree.minimumExtent(along: .vertical, leafMinimum: 10, dividerWidth: 1), 32)
    XCTAssertEqual(tree.minimumExtent(along: .horizontal, leafMinimum: 3, dividerWidth: 1), 7)
    XCTAssertEqual(first.minimumExtent(along: .vertical, leafMinimum: 10, dividerWidth: 1), 10)
  }

  func testFractionRangeKeepsBothSidesAboveMinimum() throws {
    let area = CGRect(x: 0, y: 0, width: 1000, height: 600)
    let tree = leftAndStackedRight
    let root = try XCTUnwrap(
      tree.fractionRange(
        at: [], in: area, minimumWidth: 100, minimumHeight: 30, dividerWidth: 1))
    XCTAssertEqual(root.lowerBound, 0.1, accuracy: 1e-9)
    XCTAssertEqual(root.upperBound, 0.899, accuracy: 1e-9)
    let inner = try XCTUnwrap(
      tree.fractionRange(
        at: [.second], in: area, minimumWidth: 100, minimumHeight: 30, dividerWidth: 1))
    XCTAssertEqual(inner.lowerBound, 0.05, accuracy: 1e-9, "30 / 600 is below the sanity floor")
    XCTAssertEqual(inner.upperBound, 569.0 / 600, accuracy: 1e-9)
    let tight = try XCTUnwrap(
      tree.fractionRange(
        at: [], in: CGRect(x: 0, y: 0, width: 150, height: 600), minimumWidth: 100,
        minimumHeight: 30, dividerWidth: 1))
    XCTAssertEqual(tight.lowerBound, tight.upperBound, "too small for both: one value")
    XCTAssertEqual(tight.lowerBound, 0.5 * (100.0 / 150 + 49.0 / 150), accuracy: 1e-9)
    XCTAssertNil(
      tree.fractionRange(
        at: [.first], in: area, minimumWidth: 100, minimumHeight: 30, dividerWidth: 1))
    // Nested subtree minimums: the root's second side holds (B / C) | D.
    let deep = try XCTUnwrap(
      stackedBetweenColumns.fractionRange(
        at: [], in: area, minimumWidth: 100, minimumHeight: 30, dividerWidth: 1))
    XCTAssertEqual(deep.upperBound, (1000.0 - 1 - 201) / 1000, accuracy: 1e-9)
  }

  func testNudgeTargetFindsNearestEnclosingSplitOnThatSide() {
    let tree = stackedBetweenColumns  // A | ((B / C) | D)
    XCTAssertEqual(tree.nudgeTarget(for: "left", direction: .right), [])
    XCTAssertNil(tree.nudgeTarget(for: "left", direction: .left))
    XCTAssertEqual(tree.nudgeTarget(for: "right", direction: .right), [.second])
    XCTAssertEqual(tree.nudgeTarget(for: "right", direction: .left), [])
    XCTAssertEqual(tree.nudgeTarget(for: "D", direction: .left), [.second])
    XCTAssertEqual(tree.nudgeTarget(for: "right", direction: .down), [.second, .first])
    XCTAssertNil(tree.nudgeTarget(for: "right", direction: .up))
    XCTAssertEqual(tree.nudgeTarget(for: "C", direction: .up), [.second, .first])
    XCTAssertNil(tree.nudgeTarget(for: "missing", direction: .right))
  }

  func testPreviewRectCentresOnProposedPositionAndSpansContainer() {
    let container = CGRect(x: 200, y: 10, width: 900, height: 600)
    let vertical = PaneDivider.previewRect(axis: .vertical, container: container, fraction: 1.0 / 3)
    XCTAssertEqual(vertical.width, PaneDivider.previewThickness)
    XCTAssertEqual(vertical.minY, 10)
    XCTAssertEqual(vertical.height, 600)
    XCTAssertEqual(vertical.midX, 200 + 300, accuracy: 0.5)
    let horizontal = PaneDivider.previewRect(
      axis: .horizontal, container: container, fraction: 0.25)
    XCTAssertEqual(horizontal.height, PaneDivider.previewThickness)
    XCTAssertEqual(horizontal.minX, 200)
    XCTAssertEqual(horizontal.width, 900)
    // y grows upward: 25% from the top of the container is 150 below its maxY.
    XCTAssertEqual(horizontal.midY, 10 + 600 - 150, accuracy: 0.5)
  }

  func testFirstChildOfHorizontalSplitSitsAboveSecondInUpwardCoordinates() {
    let area = CGRect(x: 0, y: 0, width: 1000, height: 600)
    let top = rect(leftAndStackedRight, "right", in: area)
    let bottom = rect(leftAndStackedRight, "C", in: area)
    XCTAssertGreaterThan(top.minY, bottom.maxY - 0.001, "first is the upper pane (y grows up)")
  }

  func testDragMathMeasuresHorizontalFractionDownFromTheTop() {
    let container = CGRect(x: 0, y: 0, width: 1000, height: 600)
    var drag = PaneDividerDrag(
      tabId: "t", path: [], axis: .horizontal, container: container, fraction: 0.5,
      grabbedAt: CGPoint(x: 0, y: 300), splitLeaves: [])
    drag.moveTo(x: 0, y: 450)
    XCTAssertEqual(drag.fraction, 0.25, accuracy: 1e-9, "150 up from the grab is 25% further up")
    XCTAssertTrue(drag.hasMoved)
    XCTAssertEqual(drag.previewRect.midY, 450, accuracy: 0.5)
  }

  func testDragFollowsPointerMovementFromAnOffCentreGrab() {
    let container = CGRect(x: 100, y: 0, width: 1000, height: 600)
    // Pressed 3 px right of the divider line, inside the grab zone.
    var drag = PaneDividerDrag(
      tabId: "t", path: [], axis: .vertical, container: container, fraction: 0.5,
      grabbedAt: CGPoint(x: 100 + 500 + 3, y: 300), splitLeaves: [])
    drag.moveTo(x: 603, y: 300)
    XCTAssertFalse(drag.hasMoved, "releasing where it was pressed is a bare click")
    XCTAssertEqual(drag.fraction, 0.5)
    drag.moveTo(x: 503, y: 120)
    XCTAssertEqual(drag.fraction, 0.4, accuracy: 1e-9, "the divider moves by the pointer's delta")
  }
}
