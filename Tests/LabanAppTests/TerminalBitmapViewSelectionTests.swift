import AppKit
import LabanCore
import LabanRenderer
import LabanTerminalCore
import XCTest

@testable import LabanApp

final class TerminalBitmapViewSelectionTests: XCTestCase {
  func testNewTabClearsSelectionBeforeNextFrame() throws {
    let harness = try makeHarness()
    defer { harness.restoreRenderer() }

    let first = try XCTUnwrap(harness.model.activeTab)
    let firstSession = try XCTUnwrap(harness.model.session(forTab: first.id))
    firstSession.write(Array("ONE first\r\n".utf8))
    firstSession.poll()
    harness.view.advanceFrame()

    selectCells(row: 0, startCol: 0, endCol: 2, in: harness)
    XCTAssertEqual(copyText(from: harness.view), "ONE")

    harness.view.newTab(nil)
    let second = try XCTUnwrap(harness.model.activeTab)
    XCTAssertNotEqual(second.id, first.id)
    let secondSession = try XCTUnwrap(harness.model.session(forTab: second.id))
    secondSession.write(Array("TWO second\r\n".utf8))
    secondSession.poll()

    setPasteboard("sentinel")
    harness.view.copy(nil)
    XCTAssertEqual(
      NSPasteboard.general.string(forType: .string),
      "sentinel",
      "newly created tab must not inherit the previous tab's selection before the next frame"
    )
  }

  func testMenuTabSelectionRestoresSelectionBeforeNextFrame() throws {
    let harness = try makeHarness()
    defer { harness.restoreRenderer() }

    let first = try XCTUnwrap(harness.model.activeTab)
    let firstSession = try XCTUnwrap(harness.model.session(forTab: first.id))
    firstSession.write(Array("ONE first\r\n".utf8))
    firstSession.poll()
    harness.view.advanceFrame()

    selectCells(row: 0, startCol: 0, endCol: 2, in: harness)
    XCTAssertEqual(copyText(from: harness.view), "ONE")

    harness.view.newTab(nil)
    harness.view.advanceFrame()

    let item = NSMenuItem(title: "Tab 1", action: nil, keyEquivalent: "")
    item.tag = 1
    harness.view.selectTabByIndex(item)

    XCTAssertEqual(
      copyText(from: harness.view),
      "ONE",
      "switching back by menu must restore that tab's cached selection synchronously"
    )
  }

  func testColumnChangingResizeClearsCachedInactiveSelections() throws {
    let harness = try makeHarness()
    defer { harness.restoreRenderer() }

    let first = try XCTUnwrap(harness.model.activeTab)
    let firstSession = try XCTUnwrap(harness.model.session(forTab: first.id))
    firstSession.write(Array("ONE first\r\n".utf8))
    firstSession.poll()
    harness.view.advanceFrame()

    selectCells(row: 0, startCol: 0, endCol: 2, in: harness)
    XCTAssertEqual(copyText(from: harness.view), "ONE")

    harness.view.newTab(nil)
    harness.view.advanceFrame()

    let resizedWidth =
      SidebarLayout.defaultWidth + harness.insets.left
      + CGFloat(harness.cols + 5) * CGFloat(harness.cellWidth) + harness.insets.right
    harness.view.setFrameSize(NSSize(width: resizedWidth, height: harness.view.frame.height))

    let item = NSMenuItem(title: "Tab 1", action: nil, keyEquivalent: "")
    item.tag = 1
    harness.view.selectTabByIndex(item)
    harness.view.advanceFrame()

    setPasteboard("sentinel")
    harness.view.copy(nil)
    XCTAssertEqual(
      NSPasteboard.general.string(forType: .string),
      "sentinel",
      "column-changing resize must drop cached selections for inactive tabs as well"
    )
  }

  func testClosingLastRenderedInactiveTabKeepsActiveSelection() throws {
    let harness = try makeHarness()
    defer { harness.restoreRenderer() }

    let first = try XCTUnwrap(harness.model.activeTab)
    let firstSession = try XCTUnwrap(harness.model.session(forTab: first.id))
    firstSession.write(Array("ONE first\r\n".utf8))
    firstSession.poll()
    harness.view.advanceFrame()

    selectCells(row: 0, startCol: 0, endCol: 2, in: harness)
    XCTAssertEqual(copyText(from: harness.view), "ONE")

    harness.view.newTab(nil)
    let second = try XCTUnwrap(harness.model.activeTab)
    let secondSession = try XCTUnwrap(harness.model.session(forTab: second.id))
    secondSession.write(Array("TWO second\r\n".utf8))
    secondSession.poll()

    selectCells(row: 0, startCol: 0, endCol: 2, in: harness)
    XCTAssertEqual(copyText(from: harness.view), "TWO")

    clickCloseButton(tabIndex: 0, in: harness)
    XCTAssertNil(harness.model.session(forTab: first.id))
    XCTAssertEqual(harness.model.activeTab?.id, second.id)

    XCTAssertEqual(
      copyText(from: harness.view),
      "TWO",
      "closing an inactive tab that was last rendered must not clear the active tab selection"
    )
  }

  func testScrollWheelKeepsSelectionAttachedToContent() throws {
    let harness = try makeHarness(rows: 5, cols: 20)
    defer { harness.restoreRenderer() }

    let tab = try XCTUnwrap(harness.model.activeTab)
    let session = try XCTUnwrap(harness.model.session(forTab: tab.id))
    let history = (1...12).map { String(format: "line %02d\r\n", $0) }.joined()
    session.write(Array(history.utf8))
    session.poll()
    harness.view.advanceFrame()

    let initialViewport = try XCTUnwrap(session.viewportState())
    XCTAssertGreaterThan(initialViewport.scrollbackRows, 0)

    selectCells(row: 2, startCol: 0, endCol: 6, in: harness)
    let selectedBeforeScroll = try XCTUnwrap(copyText(from: harness.view))
    XCTAssertTrue(selectedBeforeScroll.hasPrefix("line "))

    scrollOneRowTowardHistory(in: harness, session: session)

    XCTAssertEqual(
      copyText(from: harness.view),
      selectedBeforeScroll,
      "scrolling while a selection is active must keep copy attached to the selected content"
    )
  }

  private struct Harness {
    var model: AppModel
    var view: TerminalBitmapView
    var rows: Int
    var cols: Int
    var cellWidth: Int
    var cellHeight: Int
    var sidebarCellWidth: Int
    var sidebarCellHeight: Int
    var insets: NSEdgeInsets
    var oldRenderer: String?

    func restoreRenderer() {
      if let oldRenderer {
        setenv("LABAN_RENDERER", oldRenderer, 1)
      } else {
        unsetenv("LABAN_RENDERER")
      }
    }
  }

  private func makeHarness(rows: Int32 = 5, cols: Int32 = 20) throws -> Harness {
    let oldRenderer = getenv("LABAN_RENDERER").map { String(cString: $0) }
    setenv("LABAN_RENDERER", "software", 1)

    var size = LabanTerminalSize()
    size.rows = rows
    size.cols = cols
    let model = try AppModel(initialSize: size) { try Session.fixture(size: $0) }

    let fontAtlas = FontAtlas(pointSize: 14)
    let sidebarFontAtlas = FontAtlas(pointSize: 11)
    let cellSize = fontAtlas.cellSize
    let cellWidth = Int(cellSize.width)
    let cellHeight = Int(cellSize.height)
    let insets = TerminalBitmapView.contentInsets
    let viewWidth =
      SidebarLayout.defaultWidth + insets.left + CGFloat(cols) * CGFloat(cellWidth)
      + insets.right
    let viewHeight = insets.top + CGFloat(rows) * CGFloat(cellHeight) + insets.bottom

    let view = TerminalBitmapView(
      model: model,
      fontAtlas: fontAtlas,
      sidebarFontAtlas: sidebarFontAtlas,
      cellWidth: cellWidth,
      cellHeight: cellHeight
    )
    view.frame = NSRect(x: 0, y: 0, width: viewWidth, height: viewHeight)

    return Harness(
      model: model,
      view: view,
      rows: Int(rows),
      cols: Int(cols),
      cellWidth: cellWidth,
      cellHeight: cellHeight,
      sidebarCellWidth: Int(sidebarFontAtlas.cellSize.width),
      sidebarCellHeight: Int(sidebarFontAtlas.cellSize.height),
      insets: insets,
      oldRenderer: oldRenderer)
  }

  private func selectCells(row: Int, startCol: Int, endCol: Int, in harness: Harness) {
    let start = point(row: row, col: startCol, in: harness)
    let end = point(row: row, col: endCol, in: harness)
    harness.view.mouseDown(with: mouseEvent(type: .leftMouseDown, at: start))
    harness.view.mouseDragged(with: mouseEvent(type: .leftMouseDragged, at: end))
    harness.view.mouseUp(with: mouseEvent(type: .leftMouseUp, at: end))
  }

  private func point(row: Int, col: Int, in harness: Harness) -> NSPoint {
    NSPoint(
      x: SidebarLayout.defaultWidth + harness.insets.left
        + CGFloat(col) * CGFloat(harness.cellWidth) + CGFloat(harness.cellWidth) / 2,
      y: harness.insets.bottom + CGFloat(harness.rows - 1 - row) * CGFloat(harness.cellHeight)
        + CGFloat(harness.cellHeight) / 2
    )
  }

  private func mouseEvent(type: NSEvent.EventType, at point: NSPoint) -> NSEvent {
    NSEvent.mouseEvent(
      with: type,
      location: point,
      modifierFlags: [],
      timestamp: 0,
      windowNumber: 0,
      context: nil,
      eventNumber: 0,
      clickCount: 1,
      pressure: 1
    )!
  }

  private func clickCloseButton(tabIndex: Int, in harness: Harness) {
    let producer = SidebarProducer(
      sidebarWidth: SidebarLayout.defaultWidth,
      cellWidth: CGFloat(harness.sidebarCellWidth),
      cellHeight: CGFloat(harness.sidebarCellHeight)
    )
    let rowTop =
      harness.view.frame.height - TerminalBitmapView.titlebarReservedHeight
      - CGFloat(tabIndex) * producer.rowHeight
    let point = NSPoint(x: SidebarLayout.defaultWidth - 10, y: rowTop - 8)
    harness.view.mouseDown(with: mouseEvent(type: .leftMouseDown, at: point))
  }

  private func scrollOneRowTowardHistory(in harness: Harness, session: Session) {
    let before = session.viewportState()?.viewportOffset
    for wheelDelta in [1, -1] {
      let event = CGEvent(
        scrollWheelEvent2Source: nil,
        units: .line,
        wheelCount: 1,
        wheel1: Int32(wheelDelta),
        wheel2: 0,
        wheel3: 0
      )!
      event.location = point(row: 2, col: 0, in: harness)
      harness.view.scrollWheel(with: NSEvent(cgEvent: event)!)
      let after = session.viewportState()?.viewportOffset
      if before != after {
        return
      }
    }
    XCTFail("expected one scroll-wheel direction to move the viewport toward history")
  }

  private func copyText(from view: TerminalBitmapView) -> String? {
    setPasteboard("sentinel")
    view.copy(nil)
    return NSPasteboard.general.string(forType: .string)
  }

  private func setPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }
}
