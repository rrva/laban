import Foundation
import XCTest

@testable import LabanCore

final class TabVisibleLayoutTests: XCTestCase {
  let area = CGRect(x: 200, y: 0, width: 1000, height: 600)

  /// `A | (B / C)` with focus on `A`.
  func makeTab() -> Tab {
    var tab = Tab(id: "tab", position: 1, title: "Tab 1", isActive: true, sessionId: "A")
    tab.panes = .split(
      axis: .vertical, fraction: 0.5, first: .leaf(sessionId: "A"),
      second: .split(
        axis: .horizontal, fraction: 0.5, first: .leaf(sessionId: "B"),
        second: .leaf(sessionId: "C")))
    return tab
  }

  func testUnzoomedVisibleLayoutIsWholeTree() {
    let tab = makeTab()
    XCTAssertFalse(tab.isZoomed)
    XCTAssertEqual(tab.visiblePaneCount, 3)
    XCTAssertEqual(tab.visibleLayout(in: area), tab.panes.layout(in: area))
    XCTAssertEqual(tab.visibleDividers(in: area), tab.panes.dividers(in: area))
    XCTAssertEqual(tab.visibleDividers(in: area).count, 2)
  }

  func testZoomedVisibleLayoutIsOneFullAreaPaneWithoutDividers() {
    var tab = makeTab()
    tab.zoomedSessionId = "B"
    XCTAssertTrue(tab.isZoomed)
    XCTAssertEqual(tab.visiblePaneCount, 1)
    XCTAssertEqual(tab.visibleLayout(in: area), [PaneRect(sessionId: "B", rect: area)])
    XCTAssertTrue(tab.visibleDividers(in: area).isEmpty)
    XCTAssertEqual(tab.allSessionIds, ["A", "B", "C"], "hidden panes stay in the tree")
  }

  func testZoomOfSessionNotInTreeIsIgnored() {
    var tab = makeTab()
    tab.zoomedSessionId = "gone"
    XCTAssertFalse(tab.isZoomed)
    XCTAssertEqual(tab.visiblePaneCount, 3)
    XCTAssertEqual(tab.visibleLayout(in: area), tab.panes.layout(in: area))
    XCTAssertEqual(tab.visibleDividers(in: area).count, 2)
  }

  func testFocusingKeepsZoomState() {
    var tab = makeTab()
    tab.zoomedSessionId = "B"
    XCTAssertEqual(tab.focusing("C").zoomedSessionId, "B")
  }
}
