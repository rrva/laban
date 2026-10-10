import AppKit
import LabanCore
import LabanRenderer
import LabanTerminalCore
import XCTest

@testable import LabanApp

/// Divider hover, drag-preview-commit, double-click equalize, Escape-cancel and the
/// accessibility splitters on the AppKit view, plus pane geometry for stacked panes.
final class TerminalBitmapViewDividerTests: XCTestCase {
  private struct Harness {
    var model: AppModel
    var view: TerminalBitmapView
    var sidebarWidth: CGFloat
    var cellWidth: CGFloat
    var cellHeight: CGFloat
    var oldRenderer: String?

    var area: CGRect {
      CGRect(
        x: sidebarWidth, y: 0, width: view.bounds.width - sidebarWidth, height: view.bounds.height)
    }

    func restoreRenderer() {
      if let oldRenderer {
        setenv("LABAN_RENDERER", oldRenderer, 1)
      } else {
        unsetenv("LABAN_RENDERER")
      }
    }

    var tab: Tab { model.activeTab! }
    var dividers: [PaneDivider] { tab.visibleDividers(in: area) }
    var focused: Session.ID { tab.focusedSessionId }
  }

  private func makeHarness(rows: Int32 = 30, cols: Int32 = 120) throws -> Harness {
    let oldRenderer = getenv("LABAN_RENDERER").map { String(cString: $0) }
    setenv("LABAN_RENDERER", "software", 1)
    var size = LabanTerminalSize()
    size.rows = rows
    size.cols = cols
    let model = try AppModel(
      initialSize: size,
      sessionFactory: { size, context in
        try Session.fixture(size: size, sessionID: context.sessionID)
      })
    let fontAtlas = FontAtlas(pointSize: 14)
    let sidebarFontAtlas = FontAtlas(pointSize: 11)
    let cellWidth = Int(fontAtlas.cellSize.width)
    let cellHeight = Int(fontAtlas.cellSize.height)
    let insets = TerminalBitmapView.contentInsets
    let view = TerminalBitmapView(
      model: model, fontAtlas: fontAtlas, sidebarFontAtlas: sidebarFontAtlas,
      cellWidth: cellWidth, cellHeight: cellHeight)
    view.frame = NSRect(
      x: 0, y: 0,
      width: SidebarLayout.defaultWidth + insets.left + CGFloat(cols) * CGFloat(cellWidth)
        + insets.right,
      height: insets.top + CGFloat(rows) * CGFloat(cellHeight) + insets.bottom)
    view.advanceFrame()
    return Harness(
      model: model, view: view, sidebarWidth: view.sidebarWidthsForTesting.hitTest,
      cellWidth: CGFloat(cellWidth), cellHeight: CGFloat(cellHeight), oldRenderer: oldRenderer)
  }

  private func mouseEvent(
    _ type: NSEvent.EventType, at point: NSPoint, clickCount: Int = 1
  ) -> NSEvent {
    NSEvent.mouseEvent(
      with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: 0,
      context: nil, eventNumber: 0, clickCount: clickCount, pressure: 1)!
  }

  private func escapeKeyDown() -> NSEvent {
    NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
      context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
      isARepeat: false, keyCode: 53)!
  }

  private func fraction(_ harness: Harness, path: PanePath = []) -> Double? {
    harness.dividers.first { $0.path == path }?.fraction
  }

  private func sizes(_ harness: Harness) -> [Session.ID: [UInt32]] {
    Dictionary(
      uniqueKeysWithValues: harness.tab.allSessionIds.map { id in
        let size = harness.model.terminalSize(for: id)
        return (id, [UInt32(size.cols), UInt32(size.rows)])
      })
  }

  private func midPoint(of divider: PaneDivider) -> NSPoint {
    NSPoint(x: divider.rect.midX, y: divider.rect.midY)
  }

  // MARK: - Drag

  func testDividerDragDoesNotResizeBeforeRelease() throws {
    let harness = try makeHarness()
    defer { harness.restoreRenderer() }
    harness.view.splitPaneRight(nil)
    harness.view.advanceFrame()
    let divider = try XCTUnwrap(harness.dividers.first)
    XCTAssertEqual(divider.fraction, 0.5, accuracy: 0.001)
    let before = sizes(harness)
    let target = divider.container.minX + divider.container.width * 0.3

    harness.view.mouseDown(with: mouseEvent(.leftMouseDown, at: midPoint(of: divider)))
    XCTAssertEqual(
      try XCTUnwrap(harness.view.dividerPreviewRectForTests).midX, divider.rect.midX, accuracy: 2,
      "pressing highlights the divider where it sits")
    harness.view.mouseDragged(
      with: mouseEvent(.leftMouseDragged, at: NSPoint(x: target, y: divider.rect.midY)))
    harness.view.mouseDragged(
      with: mouseEvent(.leftMouseDragged, at: NSPoint(x: target, y: divider.rect.midY)))

    XCTAssertEqual(
      try XCTUnwrap(fraction(harness)), 0.5, accuracy: 0.001, "the tree is untouched mid-drag")
    XCTAssertEqual(sizes(harness), before, "no PTY resize mid-drag")
    let preview = try XCTUnwrap(harness.view.dividerPreviewRectForTests)
    XCTAssertEqual(preview.width, PaneDivider.previewThickness)
    XCTAssertEqual(preview.midX, target, accuracy: 2)
    XCTAssertEqual(try XCTUnwrap(harness.view.dividerDragFractionForTests), 0.3, accuracy: 0.01)

    harness.view.mouseUp(
      with: mouseEvent(.leftMouseUp, at: NSPoint(x: target, y: divider.rect.midY)))
    let committed = try XCTUnwrap(fraction(harness))
    XCTAssertEqual(committed, 0.3, accuracy: 0.02, "commit lands within a cell of the release")
    XCTAssertNotEqual(sizes(harness), before, "the shells resize once, on release")
    XCTAssertNil(harness.view.dividerPreviewRectForTests, "the preview is gone after release")
    XCTAssertNil(harness.view.dividerDragFractionForTests)
  }

  func testEscapeDuringDragCancelsWithoutResizing() throws {
    let harness = try makeHarness()
    defer { harness.restoreRenderer() }
    harness.view.splitPaneRight(nil)
    harness.view.advanceFrame()
    let divider = try XCTUnwrap(harness.dividers.first)
    let before = sizes(harness)
    harness.view.mouseDown(with: mouseEvent(.leftMouseDown, at: midPoint(of: divider)))
    harness.view.mouseDragged(
      with: mouseEvent(
        .leftMouseDragged, at: NSPoint(x: divider.container.minX + 200, y: divider.rect.midY)))
    XCTAssertNotNil(harness.view.dividerPreviewRectForTests)
    harness.view.keyDown(with: escapeKeyDown())
    XCTAssertNil(harness.view.dividerPreviewRectForTests)
    harness.view.mouseUp(
      with: mouseEvent(
        .leftMouseUp, at: NSPoint(x: divider.container.minX + 200, y: divider.rect.midY)))
    XCTAssertEqual(try XCTUnwrap(fraction(harness)), 0.5, accuracy: 0.001)
    XCTAssertEqual(sizes(harness), before)
  }

  func testClickOnDividerWithoutMovingChangesNothing() throws {
    let harness = try makeHarness()
    defer { harness.restoreRenderer() }
    harness.view.splitPaneRight(nil)
    harness.view.advanceFrame()
    let divider = try XCTUnwrap(harness.dividers.first)
    let focusedBefore = harness.focused
    let before = sizes(harness)
    harness.view.mouseDown(with: mouseEvent(.leftMouseDown, at: midPoint(of: divider)))
    harness.view.mouseUp(with: mouseEvent(.leftMouseUp, at: midPoint(of: divider)))
    XCTAssertEqual(try XCTUnwrap(fraction(harness)), 0.5, accuracy: 0.001)
    XCTAssertEqual(sizes(harness), before)
    XCTAssertEqual(harness.focused, focusedBefore)
  }

  func testOffCentreClickInGrabZoneChangesNothing() throws {
    let harness = try makeHarness()
    defer { harness.restoreRenderer() }
    harness.view.splitPaneRight(nil)
    harness.view.advanceFrame()
    let divider = try XCTUnwrap(harness.dividers.first)
    let before = sizes(harness)
    let press = NSPoint(x: divider.rect.midX + 2.5, y: divider.rect.midY)
    harness.view.mouseDown(with: mouseEvent(.leftMouseDown, at: press))
    harness.view.mouseUp(with: mouseEvent(.leftMouseUp, at: press))
    XCTAssertEqual(try XCTUnwrap(fraction(harness)), divider.fraction, "a bare click moves nothing")
    XCTAssertEqual(sizes(harness), before, "a bare click resizes no shell")
  }

  func testEscapeMidDragDoesNotFallThroughToSelection() throws {
    let harness = try makeHarness()
    defer { harness.restoreRenderer() }
    harness.view.splitPaneRight(nil)
    harness.view.advanceFrame()
    let pane = try XCTUnwrap(
      harness.tab.visibleLayout(in: harness.area).first { $0.sessionId == harness.focused })
    let session = try XCTUnwrap(harness.model.session(forSessionID: harness.focused))
    session.write(Array("alpha bravo\r\n".utf8))
    session.poll()
    harness.view.advanceFrame()
    func cell(_ col: Int) -> NSPoint { point(row: 0, col: col, in: pane.rect, harness) }
    harness.view.mouseDown(with: mouseEvent(.leftMouseDown, at: cell(0)))
    harness.view.mouseDragged(with: mouseEvent(.leftMouseDragged, at: cell(4)))
    harness.view.mouseUp(with: mouseEvent(.leftMouseUp, at: cell(4)))
    XCTAssertEqual(copyText(harness), "alpha")

    let divider = try XCTUnwrap(harness.dividers.first)
    harness.view.mouseDown(with: mouseEvent(.leftMouseDown, at: midPoint(of: divider)))
    harness.view.mouseDragged(
      with: mouseEvent(
        .leftMouseDragged, at: NSPoint(x: divider.rect.midX - 40, y: divider.rect.midY)))
    harness.view.keyDown(with: escapeKeyDown())
    harness.view.mouseDragged(with: mouseEvent(.leftMouseDragged, at: cell(10)))
    harness.view.mouseUp(with: mouseEvent(.leftMouseUp, at: cell(10)))
    XCTAssertEqual(copyText(harness), "alpha", "the cancelled drag must not extend the selection")
  }

  func testSelectingInTheShorterLowerPaneUsesThatPanesRows() throws {
    let harness = try makeHarness()
    defer { harness.restoreRenderer() }
    let top = harness.focused
    harness.view.splitPaneDown(nil)
    let bottom = harness.focused
    try harness.model.setSplitFraction(inTab: harness.tab.id, path: [], fraction: 0.7)
    harness.view.advanceFrame()
    harness.model.focusPane(inTab: harness.tab.id, sessionId: top)
    harness.view.advanceFrame()
    XCTAssertGreaterThan(
      harness.model.terminalSize(for: top).rows, harness.model.terminalSize(for: bottom).rows)
    let pane = try XCTUnwrap(
      harness.tab.visibleLayout(in: harness.area).first { $0.sessionId == bottom })
    let session = try XCTUnwrap(harness.model.session(forSessionID: bottom))
    session.write(Array("alpha bravo\r\n".utf8))
    session.poll()
    harness.view.advanceFrame()

    // One gesture focuses the lower pane and selects in it, before any render.
    let start = point(row: 0, col: 0, in: pane.rect, harness)
    let end = point(row: 0, col: 4, in: pane.rect, harness)
    harness.view.mouseDown(with: mouseEvent(.leftMouseDown, at: start))
    harness.view.mouseDragged(with: mouseEvent(.leftMouseDragged, at: end))
    harness.view.mouseUp(with: mouseEvent(.leftMouseUp, at: end))
    XCTAssertEqual(harness.focused, bottom)
    XCTAssertEqual(copyText(harness), "alpha")
  }

  /// The centre of `(row, col)` in a pane drawn in `rect`; row 0 is the pane's top row.
  private func point(row: Int, col: Int, in rect: CGRect, _ harness: Harness) -> NSPoint {
    let insets = paneInsets(rect, harness)
    return NSPoint(
      x: rect.minX + insets.left + (CGFloat(col) + 0.5) * harness.cellWidth,
      y: rect.maxY - insets.top - (CGFloat(row) + 0.5) * harness.cellHeight)
  }

  /// The insets of the pane drawn in `rect`: window insets at the window edges only.
  private func paneInsets(_ rect: CGRect, _ harness: Harness) -> TerminalSurfaceInsets {
    let window = TerminalBitmapView.contentInsets
    return TerminalSurfaceInsets(
      top: window.top, left: window.left, bottom: window.bottom, right: window.right
    ).forPane(rect, in: harness.area)
  }

  private func copyText(_ harness: Harness) -> String? {
    harness.view.pasteboardStringForTesting = "sentinel"
    harness.view.copy(nil)
    return harness.view.pasteboardStringForTesting
  }

  func testDoubleClickOnDividerEqualizes() throws {
    let harness = try makeHarness()
    defer { harness.restoreRenderer() }
    harness.view.splitPaneRight(nil)
    harness.view.advanceFrame()
    let tabId = harness.tab.id
    try harness.model.setSplitFraction(inTab: tabId, path: [], fraction: 0.3)
    harness.view.advanceFrame()
    let divider = try XCTUnwrap(harness.dividers.first)
    XCTAssertEqual(divider.fraction, 0.3, accuracy: 0.02)
    harness.view.mouseDown(with: mouseEvent(.leftMouseDown, at: midPoint(of: divider)))
    harness.view.mouseUp(with: mouseEvent(.leftMouseUp, at: midPoint(of: divider)))
    harness.view.mouseDown(
      with: mouseEvent(.leftMouseDown, at: midPoint(of: divider), clickCount: 2))
    harness.view.mouseUp(with: mouseEvent(.leftMouseUp, at: midPoint(of: divider), clickCount: 2))
    XCTAssertEqual(try XCTUnwrap(fraction(harness)), 0.5, accuracy: 0.001)
  }

  func testDividerHitUsesGrabZoneAndIgnoresZoomedTab() throws {
    let harness = try makeHarness()
    defer { harness.restoreRenderer() }
    harness.view.splitPaneRight(nil)
    harness.view.advanceFrame()
    let divider = try XCTUnwrap(harness.dividers.first)
    let zone = TerminalBitmapView.dividerGrabZone
    XCTAssertNotNil(
      harness.view.dividerHit(at: NSPoint(x: divider.rect.midX - zone, y: divider.rect.midY)))
    XCTAssertNil(
      harness.view.dividerHit(
        at: NSPoint(x: divider.rect.maxX + zone + 1, y: divider.rect.midY)))
    harness.view.togglePaneZoom(nil)
    XCTAssertNil(harness.view.dividerHit(at: midPoint(of: divider)), "no dividers while zoomed")
  }

  func testPressOnDividerIsNotSentToMouseTrackingApp() throws {
    let harness = try makeHarness()
    defer { harness.restoreRenderer() }
    let left = harness.focused
    harness.view.splitPaneRight(nil)
    let right = harness.focused
    for id in [left, right] {
      try XCTUnwrap(harness.model.session(forSessionID: id)).write(
        Array("\u{1b}[?1002h\u{1b}[?1006h".utf8))
    }
    harness.view.advanceFrame()
    let divider = try XCTUnwrap(harness.dividers.first)

    harness.view.mouseDown(with: mouseEvent(.leftMouseDown, at: midPoint(of: divider)))
    harness.view.mouseUp(with: mouseEvent(.leftMouseUp, at: midPoint(of: divider)))
    XCTAssertNil(
      harness.view.lastForwardedLeftReportForTests, "a divider press never reaches the shell")
    XCTAssertEqual(harness.focused, right, "pressing a divider does not move focus")

    // Control: a press inside a pane is still forwarded.
    let inside = NSPoint(x: divider.rect.minX - 100, y: divider.rect.midY)
    harness.view.mouseDown(with: mouseEvent(.leftMouseDown, at: inside))
    XCTAssertEqual(harness.view.lastForwardedLeftReportForTests?.sessionId, left)
    harness.view.mouseUp(with: mouseEvent(.leftMouseUp, at: inside))
  }

  // MARK: - Stacked panes

  func testSplitDownPlacesNewPaneBelowTheOriginal() throws {
    let harness = try makeHarness()
    defer { harness.restoreRenderer() }
    let original = harness.focused
    harness.view.splitPaneDown(nil)
    harness.view.advanceFrame()
    let created = harness.focused
    XCTAssertNotEqual(original, created)
    let layout = Dictionary(
      uniqueKeysWithValues: harness.tab.visibleLayout(in: harness.area).map {
        ($0.sessionId, $0.rect)
      })
    let top = try XCTUnwrap(layout[original])
    let bottom = try XCTUnwrap(layout[created])
    XCTAssertGreaterThanOrEqual(
      top.minY, bottom.maxY, "the view is y-up: the original pane is the upper one")
    XCTAssertEqual(harness.view.focusedPaneRect, bottom)

    harness.view.focusPaneByDirection(menuItem(.up))
    XCTAssertEqual(harness.focused, original, "up goes to the visually upper pane")
    harness.view.focusPaneByDirection(menuItem(.down))
    XCTAssertEqual(harness.focused, created)
  }

  func testSelectionInUpperPaneUsesItsOwnOrigin() throws {
    let harness = try makeHarness()
    defer { harness.restoreRenderer() }
    let upper = harness.focused
    harness.view.splitPaneDown(nil)
    harness.view.advanceFrame()
    let lower = harness.focused
    try XCTUnwrap(harness.model.session(forSessionID: upper)).feedOutput(
      Array("UPPER-ROW\r\nSECOND-ROW".utf8))
    try XCTUnwrap(harness.model.session(forSessionID: lower)).feedOutput(Array("LOWER-ROW".utf8))
    harness.view.advanceFrame()
    harness.view.focusPaneByDirection(menuItem(.up))
    XCTAssertEqual(harness.focused, upper)

    // The second text row of the upper pane, measured from the pane's own rectangle.
    let rect = harness.view.focusedPaneRect
    let rows = Int(harness.model.terminalSize(for: upper).rows)
    let cellHeight = harness.cellHeight
    let cellWidth = harness.cellWidth
    let insets = paneInsets(rect, harness)
    let originY = max(insets.bottom, rect.height - insets.top - CGFloat(rows) * cellHeight)
    let y = rect.minY + originY + CGFloat(rows - 2) * cellHeight + cellHeight / 2
    let x0 = rect.minX + insets.left + cellWidth / 2
    let x1 = x0 + cellWidth * 4
    harness.view.mouseDown(with: mouseEvent(.leftMouseDown, at: NSPoint(x: x0, y: y)))
    harness.view.mouseDragged(with: mouseEvent(.leftMouseDragged, at: NSPoint(x: x1, y: y)))
    harness.view.mouseUp(with: mouseEvent(.leftMouseUp, at: NSPoint(x: x1, y: y)))
    harness.view.pasteboardStringForTesting = "sentinel"
    harness.view.copy(nil)
    XCTAssertEqual(harness.view.pasteboardStringForTesting, "SECON")
  }

  // MARK: - Accessibility

  func testAccessibilitySplitterPerDivider() throws {
    let harness = try makeHarness()
    defer { harness.restoreRenderer() }
    harness.view.splitPaneRight(nil)
    harness.view.splitPaneDown(nil)
    harness.view.advanceFrame()
    XCTAssertEqual(harness.dividers.count, 2)

    func splitters() -> [NSAccessibilityElement] {
      (harness.view.accessibilityChildren() ?? []).compactMap {
        ($0 as? NSAccessibilityElement).flatMap { $0.accessibilityRole() == .splitter ? $0 : nil }
      }
    }
    let elements = splitters()
    XCTAssertEqual(elements.count, 2, "one splitter per visible divider")
    for (element, divider) in zip(elements, harness.dividers) {
      XCTAssertEqual(element.accessibilityRole(), .splitter)
      XCTAssertEqual(
        (element.accessibilityValue() as? NSNumber)?.doubleValue ?? -1, divider.fraction * 100,
        accuracy: 0.5)
      XCTAssertFalse(element.accessibilityFrame().isEmpty)
    }
    XCTAssertEqual(
      elements.map { $0.accessibilityOrientation() }, [.vertical, .horizontal])

    let root = try XCTUnwrap(elements.first)
    let before = try XCTUnwrap(fraction(harness))
    XCTAssertTrue(root.accessibilityPerformIncrement())
    XCTAssertGreaterThan(try XCTUnwrap(fraction(harness)), before, "increment grows the first pane")
    XCTAssertTrue(splitters().first!.accessibilityPerformDecrement())
    XCTAssertTrue(splitters().first!.accessibilityPerformDecrement())
    XCTAssertLessThan(try XCTUnwrap(fraction(harness)), before)
    let refreshed = splitters()
    XCTAssertEqual(
      (refreshed[0].accessibilityValue() as? NSNumber)?.doubleValue ?? -1,
      (try XCTUnwrap(fraction(harness))) * 100, accuracy: 0.5, "values are not stale")

    harness.view.togglePaneZoom(nil)
    XCTAssertTrue(splitters().isEmpty, "a zoomed tab has no dividers to expose")
  }

  func testAccessibilitySplitterKeepsIdentityAcrossIncrements() throws {
    let harness = try makeHarness()
    defer { harness.restoreRenderer() }
    harness.view.splitPaneRight(nil)
    harness.view.advanceFrame()

    func splitters() -> [NSAccessibilityElement] {
      (harness.view.accessibilityChildren() ?? []).compactMap {
        ($0 as? NSAccessibilityElement).flatMap { $0.accessibilityRole() == .splitter ? $0 : nil }
      }
    }
    let element = try XCTUnwrap(splitters().first)
    let frameBefore = element.accessibilityFrameInParentSpace()
    XCTAssertTrue(element.accessibilityPerformIncrement())
    let after = try XCTUnwrap(splitters().first)
    // VoiceOver keeps focus on the element it is interacting with only if it survives.
    XCTAssertTrue(after === element, "an increment updates the splitter in place")
    let divider = try XCTUnwrap(harness.dividers.first)
    XCTAssertEqual(
      (after.accessibilityValue() as? NSNumber)?.doubleValue ?? -1, divider.fraction * 100,
      accuracy: 0.5)
    XCTAssertGreaterThan(after.accessibilityFrameInParentSpace().midX, frameBefore.midX)
    XCTAssertEqual(after.accessibilityFrameInParentSpace().midX, divider.rect.midX, accuracy: 0.5)

    // The screen frame follows the window: it is derived from the parent, not cached.
    let window = NSWindow(
      contentRect: NSRect(x: 100, y: 100, width: 400, height: 300), styleMask: [.borderless],
      backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    window.contentView?.addSubview(harness.view)
    defer { harness.view.removeFromSuperview() }
    let screenBefore = try XCTUnwrap(splitters().first).accessibilityFrame()
    window.setFrameOrigin(NSPoint(x: 300, y: 250))
    let screenAfter = element.accessibilityFrame()
    XCTAssertEqual(screenAfter.minX - screenBefore.minX, 200, accuracy: 0.5)
    XCTAssertEqual(screenAfter.minY - screenBefore.minY, 150, accuracy: 0.5)
    XCTAssertTrue(splitters().first === element)
  }

  private func menuItem(_ direction: PaneDirection) -> NSMenuItem {
    let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    item.representedObject = direction.rawValue
    return item
  }
}
