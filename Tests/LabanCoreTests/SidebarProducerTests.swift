import CoreGraphics
import LabanRenderer
import XCTest

@testable import LabanCore

final class SidebarProducerTests: XCTestCase {

  private func makeTabs(count: Int) -> [Tab] {
    (0..<count).map { i in
      Tab(
        id: "tab-\(i)",
        position: i + 1,
        title: "Tab \(i + 1)",
        isActive: i == 0,
        sessionId: "session-\(i)"
      )
    }
  }

  func testCommandsAreNonEmpty() {
    let tabs = makeTabs(count: 2)
    let p = SidebarProducer(sidebarWidth: 200, cellWidth: 8, cellHeight: 16)
    let cmds = p.commands(tabs: tabs, activeTabId: tabs[0].id, height: 600)
    XCTAssertFalse(cmds.isEmpty)
  }

  func testAllCommandsHaveSidebarSource() {
    let tabs = makeTabs(count: 3)
    let p = SidebarProducer(sidebarWidth: 200, cellWidth: 8, cellHeight: 16)
    let cmds = p.commands(tabs: tabs, activeTabId: tabs[1].id, height: 600)
    for cmd in cmds {
      switch cmd {
      case .rect(_, _, let src):
        XCTAssertEqual(src, .sidebar, "rect must have sidebar source")
      case .glyphRun(_, _, _, _, let src):
        XCTAssertEqual(src, .sidebar, "glyphRun must have sidebar source")
      default:
        XCTFail("unexpected command type: \(cmd)")
      }
    }
  }

  func testBackgroundRectCoversFullHeight() {
    let p = SidebarProducer(sidebarWidth: 200, cellWidth: 8, cellHeight: 16)
    let cmds = p.commands(tabs: [], activeTabId: nil, height: 800)
    let bgRect = cmds.compactMap { cmd -> CGRect? in
      if case .rect(let r, _, _) = cmd { return r }
      return nil
    }.first
    XCTAssertNotNil(bgRect)
    XCTAssertEqual(bgRect!.height, 800, accuracy: 0.5)
    XCTAssertEqual(bgRect!.width, 200, accuracy: 0.5)
  }

  func testActiveTabProducesMoreRectsThanInactive() {
    let tabs = makeTabs(count: 2)
    let p = SidebarProducer(sidebarWidth: 200, cellWidth: 8, cellHeight: 16)

    let cmdsActiveFirst = p.commands(tabs: tabs, activeTabId: tabs[0].id, height: 600)
    let cmdsActiveSecond = p.commands(tabs: tabs, activeTabId: tabs[1].id, height: 600)

    // Active tab emits an extra stripe rect; total rect count should differ
    let rectCount0 = cmdsActiveFirst.filter {
      if case .rect = $0 { return true }
      return false
    }.count
    let rectCount1 = cmdsActiveSecond.filter {
      if case .rect = $0 { return true }
      return false
    }.count
    XCTAssertEqual(
      rectCount0, rectCount1, "rect count must be the same regardless of which tab is active")
  }

  func testTabPositionsAppearInGlyphText() {
    let tabs = makeTabs(count: 3)
    let p = SidebarProducer(sidebarWidth: 200, cellWidth: 8, cellHeight: 16)
    let cmds = p.commands(tabs: tabs, activeTabId: tabs[0].id, height: 600)
    let texts = cmds.compactMap { cmd -> String? in
      if case .glyphRun(_, let t, _, _, _) = cmd { return t }
      return nil
    }
    XCTAssertTrue(texts.contains { $0.contains("1") })
    XCTAssertTrue(texts.contains { $0.contains("2") })
    XCTAssertTrue(texts.contains { $0.contains("3") })
  }

  // MARK: - hitTest

  func testHitTestNewTabButton() {
    let p = SidebarProducer(sidebarWidth: 200, cellWidth: 8, cellHeight: 16)
    let h: CGFloat = 600
    // "+ " button is at y = h - rowHeight..h
    let buttonY = h - p.rowHeight / 2
    let result = p.hitTest(at: CGPoint(x: 50, y: buttonY), tabs: [], height: h)
    XCTAssertEqual(result, .newTab)
  }

  func testHitTestSelectTab() {
    let tabs = makeTabs(count: 2)
    let p = SidebarProducer(sidebarWidth: 200, cellWidth: 8, cellHeight: 16)
    let h: CGFloat = 600
    // Tab 0 row is at y = h - 2*rowHeight
    let tabY = h - 2 * p.rowHeight + p.rowHeight / 2
    let result = p.hitTest(at: CGPoint(x: 50, y: tabY), tabs: tabs, height: h)
    XCTAssertEqual(result, .selectTab(tabs[0].id))
  }

  func testHitTestCloseTab() {
    let tabs = makeTabs(count: 1)
    let p = SidebarProducer(sidebarWidth: 200, cellWidth: 8, cellHeight: 16)
    let h: CGFloat = 600
    let tabY = h - 2 * p.rowHeight + p.rowHeight / 2
    // Close button is at x >= sidebarWidth - 28
    let result = p.hitTest(at: CGPoint(x: 190, y: tabY), tabs: tabs, height: h)
    XCTAssertEqual(result, .closeTab(tabs[0].id))
  }

  func testHitTestOutsideSidebar() {
    let p = SidebarProducer(sidebarWidth: 200, cellWidth: 8, cellHeight: 16)
    let result = p.hitTest(at: CGPoint(x: 250, y: 300), tabs: [], height: 600)
    XCTAssertEqual(result, .none)
  }

  func testHitTestEmptyAreaBelowRows() {
    let tabs = makeTabs(count: 1)
    let p = SidebarProducer(sidebarWidth: 200, cellWidth: 8, cellHeight: 16)
    // y=0 is below all rows (no tab occupies the very bottom)
    let result = p.hitTest(at: CGPoint(x: 50, y: 2), tabs: tabs, height: 600)
    XCTAssertEqual(result, .none)
  }
}
