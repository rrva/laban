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

  func testTabSwitchDiscardsImeMarkedText() throws {
    let harness = try makeHarness()
    defer { harness.restoreRenderer() }

    let first = try XCTUnwrap(harness.model.activeTab)
    harness.view.newTab(nil)
    harness.view.advanceFrame()
    XCTAssertNotEqual(harness.model.activeTab?.id, first.id)

    // Begin an IME composition on the (now active) second tab.
    harness.view.setMarkedText(
      "か",
      selectedRange: NSRange(location: 1, length: 0),
      replacementRange: NSRange(location: NSNotFound, length: 0))
    XCTAssertTrue(harness.view.hasMarkedText(), "precondition: composition is marked")

    // Switching tabs must abandon the composition rather than leak it onto
    // the newly selected tab (which would force later keystrokes down the
    // native-text path and commit into the wrong session). (M-3)
    let item = NSMenuItem(title: "Tab 1", action: nil, keyEquivalent: "")
    item.tag = 1
    harness.view.selectTabByIndex(item)

    XCTAssertFalse(harness.view.hasMarkedText(), "tab switch must discard marked IME text")
  }

  func testSelectedRangeReportsValidInsertionPointForDictation() throws {
    let harness = try makeHarness()
    defer { harness.restoreRenderer() }

    // Idle (no IME composition): macOS dictation queries selectedRange() for
    // the insertion point before opening. A location of NSNotFound makes it
    // abort with the "ding" and never show the overlay, so the caret must be a
    // real, zero-length position.
    let idle = harness.view.selectedRange()
    XCTAssertNotEqual(
      idle.location, NSNotFound,
      "selectedRange() must expose a real insertion point or dictation/IME refuse to open")
    XCTAssertEqual(idle, NSRange(location: 0, length: 0))

    // During an IME composition the caret stays valid and inside the marked
    // range so candidate windows and accent overlays still anchor correctly.
    harness.view.setMarkedText(
      "か",
      selectedRange: NSRange(location: 1, length: 0),
      replacementRange: NSRange(location: NSNotFound, length: 0))
    XCTAssertTrue(harness.view.hasMarkedText(), "precondition: composition is marked")
    let composing = harness.view.selectedRange()
    XCTAssertNotEqual(composing.location, NSNotFound)
    let marked = harness.view.markedRange()
    XCTAssertLessThanOrEqual(
      composing.location, marked.location + marked.length,
      "caret must sit within the marked composition range")
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

  func testSelectionsInBothTabsPersistAfterRoundTrip() throws {
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
    harness.view.advanceFrame()

    selectCells(row: 0, startCol: 4, endCol: 9, in: harness)
    XCTAssertEqual(copyText(from: harness.view), "second")

    let toFirst = NSMenuItem(title: "Tab 1", action: nil, keyEquivalent: "")
    toFirst.tag = 1
    harness.view.selectTabByIndex(toFirst)
    XCTAssertEqual(
      copyText(from: harness.view),
      "ONE",
      "tab 1 selection must survive selecting in tab 2 and switching back"
    )

    let toSecond = NSMenuItem(title: "Tab 2", action: nil, keyEquivalent: "")
    toSecond.tag = 2
    harness.view.selectTabByIndex(toSecond)
    XCTAssertEqual(
      copyText(from: harness.view),
      "second",
      "tab 2 selection must survive switching back to tab 1 and forward again"
    )

    harness.view.selectTabByIndex(toFirst)
    XCTAssertEqual(
      copyText(from: harness.view),
      "ONE",
      "tab 1 selection must survive a third tab switch with no intervening edit"
    )
  }

  func testSidebarClickRoundTripPreservesBothSelections() throws {
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
    harness.view.advanceFrame()

    selectCells(row: 0, startCol: 4, endCol: 9, in: harness)
    XCTAssertEqual(copyText(from: harness.view), "second")

    clickTabRow(tabIndex: 0, in: harness)
    harness.view.advanceFrame()
    XCTAssertEqual(harness.model.activeTab?.id, first.id)
    XCTAssertEqual(
      copyText(from: harness.view),
      "ONE",
      "tab 1 selection must survive a sidebar-click round trip"
    )

    clickTabRow(tabIndex: 1, in: harness)
    harness.view.advanceFrame()
    XCTAssertEqual(harness.model.activeTab?.id, second.id)
    XCTAssertEqual(
      copyText(from: harness.view),
      "second",
      "tab 2 selection must survive a sidebar-click round trip"
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

  func testScrollWheelInTitlebarStripDoesNotScrollTerminalViewport() throws {
    let harness = try makeHarness(rows: 5, cols: 20)
    defer { harness.restoreRenderer() }

    let tab = try XCTUnwrap(harness.model.activeTab)
    let session = try XCTUnwrap(harness.model.session(forTab: tab.id))
    let history = (1...12).map { String(format: "line %02d\r\n", $0) }.joined()
    session.write(Array(history.utf8))
    session.poll()
    harness.view.advanceFrame()

    let before = try XCTUnwrap(session.viewportState()).viewportOffset
    let event = TestScrollWheelEvent(
      locationInWindow: NSPoint(
        x: SidebarLayout.defaultWidth + 50,
        y: harness.view.frame.height - TerminalBitmapView.titlebarReservedHeight / 2
      ),
      deltaY: 1
    )

    harness.view.scrollWheel(with: event)

    XCTAssertEqual(
      try XCTUnwrap(session.viewportState()).viewportOffset,
      before,
      "scroll events in the transparent titlebar strip belong to window chrome, not the terminal"
    )
  }

  func testShiftClickExtendsExistingSelectionFocus() throws {
    let harness = try makeHarness()
    defer { harness.restoreRenderer() }

    let tab = try XCTUnwrap(harness.model.activeTab)
    let session = try XCTUnwrap(harness.model.session(forTab: tab.id))
    session.write(Array("alpha bravo\r\n".utf8))
    session.poll()
    harness.view.advanceFrame()

    selectCells(row: 0, startCol: 0, endCol: 4, in: harness)
    XCTAssertEqual(copyText(from: harness.view), "alpha")

    shiftClickCell(row: 0, col: 10, in: harness)

    XCTAssertEqual(
      copyText(from: harness.view),
      "alpha bravo",
      "shift-click should keep the existing selection anchor and move the focus"
    )
  }

  func testShiftDragStartsLocalSelectionWhenMouseTrackingIsActive() throws {
    let harness = try makeHarness()
    defer { harness.restoreRenderer() }

    let tab = try XCTUnwrap(harness.model.activeTab)
    let session = try XCTUnwrap(harness.model.session(forTab: tab.id))
    session.write(Array("alpha bravo\r\n".utf8))
    session.poll()
    enableMouseTracking(in: session)
    harness.view.advanceFrame()

    shiftSelectCells(row: 0, startCol: 0, endCol: 4, in: harness)

    XCTAssertEqual(
      copyText(from: harness.view),
      "alpha",
      "holding shift should force local selection even when the terminal app tracks the mouse"
    )
  }

  func testPlainDragUnderMouseTrackingForwardsToAppInsteadOfSelectingLocally() throws {
    let harness = try makeHarness()
    defer { harness.restoreRenderer() }

    let tab = try XCTUnwrap(harness.model.activeTab)
    let session = try XCTUnwrap(harness.model.session(forTab: tab.id))
    session.write(Array("alpha bravo\r\n".utf8))
    session.poll()
    enableMouseTracking(in: session)
    harness.view.advanceFrame()

    // A plain (no-Shift) drag under mouse tracking is forwarded to the app as
    // mouse reports (the iTerm2/Ghostty model) so the app runs its own
    // selection and can scroll past one screen. It must NOT create a
    // Laban-native selection — there is nothing local to copy afterward.
    selectCells(row: 0, startCol: 0, endCol: 4, in: harness)

    XCTAssertEqual(
      copyText(from: harness.view),
      "sentinel",
      "a plain drag under mouse tracking must forward to the app, not select locally"
    )
  }

  func testShiftClickExtendsSelectionWhenMouseTrackingIsActive() throws {
    let harness = try makeHarness()
    defer { harness.restoreRenderer() }

    let tab = try XCTUnwrap(harness.model.activeTab)
    let session = try XCTUnwrap(harness.model.session(forTab: tab.id))
    session.write(Array("alpha bravo\r\n".utf8))
    session.poll()
    harness.view.advanceFrame()

    selectCells(row: 0, startCol: 0, endCol: 4, in: harness)
    XCTAssertEqual(copyText(from: harness.view), "alpha")

    enableMouseTracking(in: session)
    shiftClickCell(row: 0, col: 10, in: harness)

    XCTAssertEqual(
      copyText(from: harness.view),
      "alpha bravo",
      "holding shift should extend selection instead of sending the click to mouse tracking"
    )
  }

  func testClickClearsSelectionWhenMouseTrackingIsActive() throws {
    let harness = try makeHarness()
    defer { harness.restoreRenderer() }

    let tab = try XCTUnwrap(harness.model.activeTab)
    let session = try XCTUnwrap(harness.model.session(forTab: tab.id))
    session.write(Array("alpha bravo\r\n".utf8))
    session.poll()
    harness.view.advanceFrame()

    // Commit a selection while the app is not tracking the mouse.
    selectCells(row: 0, startCol: 0, endCol: 4, in: harness)
    XCTAssertEqual(copyText(from: harness.view), "alpha")

    // The app turns on mouse tracking (a fullscreen TUI like Claude Code). A
    // bare click must still dismiss the leftover selection instead of leaving it
    // painted while the click is forwarded to the app.
    enableMouseTracking(in: session)
    clickCell(row: 0, col: 8, in: harness)

    XCTAssertEqual(
      copyText(from: harness.view), "sentinel",
      "a click under mouse tracking must clear the existing local selection")
  }

  func testPasteClearsActiveSelection() throws {
    let harness = try makeHarness()
    defer { harness.restoreRenderer() }

    let tab = try XCTUnwrap(harness.model.activeTab)
    let session = try XCTUnwrap(harness.model.session(forTab: tab.id))
    session.write(Array("alpha bravo\r\n".utf8))
    session.poll()
    harness.view.advanceFrame()

    selectCells(row: 0, startCol: 0, endCol: 4, in: harness)
    XCTAssertEqual(copyText(from: harness.view), "alpha")

    setPasteboard("PASTED")
    harness.view.paste(nil)

    // After a paste the selection is gone, so a follow-up copy finds nothing to
    // put on the pasteboard and the sentinel survives unchanged.
    XCTAssertEqual(
      copyText(from: harness.view), "sentinel",
      "pasting must clear the on-screen selection the user pasted from")
  }

  func testWheelScrollPreservesSelectionWhenMouseTrackingIsActive() throws {
    let harness = try makeHarness()
    defer { harness.restoreRenderer() }

    let tab = try XCTUnwrap(harness.model.activeTab)
    let session = try XCTUnwrap(harness.model.session(forTab: tab.id))
    session.write(Array("alpha bravo\r\n".utf8))
    session.poll()
    harness.view.advanceFrame()

    // Commit a selection while the app is not tracking the mouse.
    selectCells(row: 0, startCol: 0, endCol: 4, in: harness)
    XCTAssertEqual(copyText(from: harness.view), "alpha")

    // A fullscreen TUI (Claude Code) turns on mouse reporting, so a plain wheel
    // is forwarded to the app. iTerm2/kitty keep the selection across a
    // forwarded scroll rather than dropping it on every notch — bumping the
    // wheel must not lose what the user selected.
    enableMouseTracking(in: session)
    harness.view.scrollWheel(
      with: TestScrollWheelEvent(
        locationInWindow: point(row: 2, col: 0, in: harness), deltaY: 1))

    XCTAssertEqual(
      copyText(from: harness.view), "alpha",
      "a wheel scroll forwarded under mouse tracking must keep the local selection")
  }

  func testAltScrollWheelPreservesSelection() throws {
    let harness = try makeHarness()
    defer { harness.restoreRenderer() }

    let tab = try XCTUnwrap(harness.model.activeTab)
    let session = try XCTUnwrap(harness.model.session(forTab: tab.id))
    enableAltScroll(in: session)
    session.write(Array("alpha bravo\r\n".utf8))
    session.poll()
    harness.view.advanceFrame()

    selectCells(row: 0, startCol: 0, endCol: 4, in: harness)
    XCTAssertEqual(copyText(from: harness.view), "alpha")

    // Alt-scroll (less/man-style) translates the wheel into the app's cursor
    // keys. Like iTerm2/kitty, a wheel notch must not discard a selection the
    // user can still copy or extend.
    harness.view.scrollWheel(
      with: TestScrollWheelEvent(
        locationInWindow: point(row: 2, col: 0, in: harness), deltaY: 1))

    XCTAssertEqual(
      copyText(from: harness.view), "alpha",
      "an alt-scroll wheel must keep the local selection")
  }

  func testShiftWheelScrollsLocalScrollbackUnderMouseTracking() throws {
    let harness = try makeHarness()
    defer { harness.restoreRenderer() }

    let tab = try XCTUnwrap(harness.model.activeTab)
    let session = try XCTUnwrap(harness.model.session(forTab: tab.id))
    // Produce scrollback above the small viewport.
    for i in 1...40 { _ = session.write(Array("line \(i)\r\n".utf8)) }
    session.poll()
    enableMouseTracking(in: session)
    harness.view.advanceFrame()

    // Plain wheel under mouse tracking is forwarded to the app (not local scroll).
    XCTAssertFalse(
      wheelMovedViewport(in: harness, session: session, shift: false),
      "plain wheel under mouse tracking must forward to the app, not scroll Laban scrollback")

    // Shift+wheel is the escape hatch: it scrolls Laban's own scrollback even
    // while the app holds the mouse.
    XCTAssertTrue(
      wheelMovedViewport(in: harness, session: session, shift: true),
      "Shift+wheel must scroll Laban's scrollback even while the app tracks the mouse")
  }

  /// Feeds wheel notches (both directions, so the test is sign-agnostic) and
  /// reports whether Laban's own viewport offset moved.
  private func wheelMovedViewport(in harness: Harness, session: Session, shift: Bool) -> Bool {
    let base = session.viewportState()?.viewportOffset ?? 0
    for delta in [CGFloat(3), CGFloat(-3)] {
      for _ in 0..<3 {
        harness.view.scrollWheel(
          with: TestScrollWheelEvent(
            locationInWindow: point(row: 2, col: 0, in: harness),
            deltaY: delta,
            modifierFlags: shift ? .shift : []))
      }
      if session.viewportState()?.viewportOffset != base { return true }
    }
    return false
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

  private func shiftSelectCells(row: Int, startCol: Int, endCol: Int, in harness: Harness) {
    let start = point(row: row, col: startCol, in: harness)
    let end = point(row: row, col: endCol, in: harness)
    harness.view.mouseDown(
      with: mouseEvent(type: .leftMouseDown, at: start, modifierFlags: .shift))
    harness.view.mouseDragged(
      with: mouseEvent(type: .leftMouseDragged, at: end, modifierFlags: .shift))
    harness.view.mouseUp(
      with: mouseEvent(type: .leftMouseUp, at: end, modifierFlags: .shift))
  }

  private func clickCell(row: Int, col: Int, in harness: Harness) {
    let point = point(row: row, col: col, in: harness)
    harness.view.mouseDown(with: mouseEvent(type: .leftMouseDown, at: point))
    harness.view.mouseUp(with: mouseEvent(type: .leftMouseUp, at: point))
  }

  private func shiftClickCell(row: Int, col: Int, in harness: Harness) {
    let point = point(row: row, col: col, in: harness)
    harness.view.mouseDown(
      with: mouseEvent(type: .leftMouseDown, at: point, modifierFlags: .shift))
    harness.view.mouseUp(
      with: mouseEvent(type: .leftMouseUp, at: point, modifierFlags: .shift))
  }

  private func point(row: Int, col: Int, in harness: Harness) -> NSPoint {
    NSPoint(
      x: SidebarLayout.defaultWidth + harness.insets.left
        + CGFloat(col) * CGFloat(harness.cellWidth) + CGFloat(harness.cellWidth) / 2,
      y: harness.insets.bottom + CGFloat(harness.rows - 1 - row) * CGFloat(harness.cellHeight)
        + CGFloat(harness.cellHeight) / 2
    )
  }

  private func mouseEvent(
    type: NSEvent.EventType,
    at point: NSPoint,
    modifierFlags: NSEvent.ModifierFlags = []
  ) -> NSEvent {
    NSEvent.mouseEvent(
      with: type,
      location: point,
      modifierFlags: modifierFlags,
      timestamp: 0,
      windowNumber: 0,
      context: nil,
      eventNumber: 0,
      clickCount: 1,
      pressure: 1
    )!
  }

  private func enableMouseTracking(in session: Session) {
    session.write(Array("\u{1B}[?1000h\u{1B}[?1006h".utf8))
    session.poll()
    XCTAssertEqual(session.viewportState()?.mouseTracking, true)
  }

  private func enableAltScroll(in session: Session) {
    // Enter the alternate screen (1049) and turn on DEC alternate-scroll (1007),
    // the less/man/vim wheel mode where the app consumes the wheel as cursor keys.
    session.write(Array("\u{1B}[?1049h\u{1B}[?1007h".utf8))
    session.poll()
    let vs = session.viewportState()
    XCTAssertEqual(vs?.altScreen, true)
    XCTAssertEqual(vs?.altScroll, true)
  }

  private func clickTabRow(tabIndex: Int, in harness: Harness) {
    let producer = SidebarProducer(
      sidebarWidth: SidebarLayout.defaultWidth,
      cellWidth: CGFloat(harness.sidebarCellWidth),
      cellHeight: CGFloat(harness.sidebarCellHeight)
    )
    let rowTop =
      harness.view.frame.height - TerminalBitmapView.titlebarReservedHeight
      - CGFloat(tabIndex) * producer.rowHeight
    let point = NSPoint(x: SidebarLayout.defaultWidth / 2, y: rowTop - producer.rowHeight / 2)
    harness.view.mouseDown(with: mouseEvent(type: .leftMouseDown, at: point))
    harness.view.mouseUp(with: mouseEvent(type: .leftMouseUp, at: point))
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
      let event = TestScrollWheelEvent(
        locationInWindow: point(row: 2, col: 0, in: harness),
        deltaY: CGFloat(wheelDelta)
      )
      harness.view.scrollWheel(with: event)
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
