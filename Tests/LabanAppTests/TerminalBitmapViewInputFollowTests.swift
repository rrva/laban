import AppKit
import CoreGraphics
import LabanCore
import LabanRenderer
import LabanTerminalCore
import XCTest

@testable import LabanApp

final class TerminalBitmapViewInputFollowTests: XCTestCase {
  func testInputCancelsPendingSmoothScrollWhenViewportStillAtBottom() throws {
    let oldRenderer = getenv("LABAN_RENDERER").map { String(cString: $0) }
    setenv("LABAN_RENDERER", "software", 1)
    defer {
      if let oldRenderer {
        setenv("LABAN_RENDERER", oldRenderer, 1)
      } else {
        unsetenv("LABAN_RENDERER")
      }
    }

    var size = LabanTerminalSize()
    size.rows = 5
    size.cols = 40
    let model = try AppModel(initialSize: size) { try Session.fixture(size: $0) }

    let fontAtlas = FontAtlas(pointSize: 14)
    let sidebarFontAtlas = FontAtlas(pointSize: 11)
    let cellSize = fontAtlas.cellSize
    let insets = TerminalBitmapView.contentInsets
    let viewWidth =
      SidebarLayout.defaultWidth + insets.left + CGFloat(size.cols) * cellSize.width
      + insets.right
    let viewHeight = insets.top + CGFloat(size.rows) * cellSize.height + insets.bottom

    let view = TerminalBitmapView(
      model: model,
      fontAtlas: fontAtlas,
      sidebarFontAtlas: sidebarFontAtlas,
      cellWidth: Int(cellSize.width),
      cellHeight: Int(cellSize.height)
    )
    view.frame = NSRect(x: 0, y: 0, width: viewWidth, height: viewHeight)

    guard let activeTab = model.activeTab,
      let session = model.session(forTab: activeTab.id)
    else {
      XCTFail("model must have an active session")
      return
    }

    let history = (1...20).map { "line \($0)\r\n" }.joined()
    session.write(Array(history.utf8))
    view.advanceFrame()

    var viewport = try XCTUnwrap(session.viewportState())
    XCTAssertGreaterThan(viewport.scrollbackRows, 0)
    XCTAssertEqual(viewport.viewportOffset, viewport.scrollbackRows)

    let event = TestScrollWheelEvent(
      locationInWindow: CGPoint(x: SidebarLayout.defaultWidth + 50, y: 50),
      deltaY: 4
    )
    view.scrollWheel(with: event)

    viewport = try XCTUnwrap(session.viewportState())
    XCTAssertEqual(
      viewport.viewportOffset,
      viewport.scrollbackRows,
      "large non-precise wheel input queues smooth scroll before the C viewport moves")

    view.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
    view.advanceFrame()

    viewport = try XCTUnwrap(session.viewportState())
    XCTAssertEqual(
      viewport.viewportOffset,
      viewport.scrollbackRows,
      "typing must cancel any queued smooth-scroll target before it can move off bottom")
  }

  /// The reported bug: a chatty app streams output while the user is scrolled
  /// back, so the live bottom moves away. Typing must snap to the *live* bottom
  /// (not a stale pin computed before the stream) and re-engage follow, so the
  /// overlay scroll indicator hides. Backed by the atomic
  /// `scrollViewportToActiveBottom` pin.
  func testTypingSnapsToLiveBottomAfterStreamingWhileScrolledBack() throws {
    let oldRenderer = getenv("LABAN_RENDERER").map { String(cString: $0) }
    setenv("LABAN_RENDERER", "software", 1)
    defer {
      if let oldRenderer {
        setenv("LABAN_RENDERER", oldRenderer, 1)
      } else {
        unsetenv("LABAN_RENDERER")
      }
    }

    var size = LabanTerminalSize()
    size.rows = 6
    size.cols = 40
    let model = try AppModel(initialSize: size) { try Session.fixture(size: $0) }

    let fontAtlas = FontAtlas(pointSize: 14)
    let sidebarFontAtlas = FontAtlas(pointSize: 11)
    let cellSize = fontAtlas.cellSize
    let insets = TerminalBitmapView.contentInsets
    let viewWidth =
      SidebarLayout.defaultWidth + insets.left + CGFloat(size.cols) * cellSize.width + insets.right
    let viewHeight = insets.top + CGFloat(size.rows) * cellSize.height + insets.bottom
    let view = TerminalBitmapView(
      model: model,
      fontAtlas: fontAtlas,
      sidebarFontAtlas: sidebarFontAtlas,
      cellWidth: Int(cellSize.width),
      cellHeight: Int(cellSize.height)
    )
    view.frame = NSRect(x: 0, y: 0, width: viewWidth, height: viewHeight)

    let activeTab = try XCTUnwrap(model.activeTab)
    let session = try XCTUnwrap(model.session(forTab: activeTab.id))

    func linesBack() throws -> Int {
      let vs = try XCTUnwrap(session.viewportState())
      return max(0, max(0, vs.totalRows - vs.viewportRows) - vs.viewportOffset)
    }

    session.write(Array((0..<120).map { "line \($0)\r\n" }.joined().utf8))
    view.advanceFrame()
    XCTAssertEqual(try linesBack(), 0, "starts pinned to the bottom")

    // Scroll back into history, then keep streaming so the live bottom moves.
    XCTAssertEqual(session.scrollViewport(deltaRows: -40), 0)
    view.advanceFrame()
    XCTAssertGreaterThan(try linesBack(), 0, "scrolled back into history")
    session.write(Array((120..<200).map { "line \($0)\r\n" }.joined().utf8))
    view.advanceFrame()
    XCTAssertGreaterThan(try linesBack(), 40, "streamed output moved the live bottom away")

    // Typing snaps to the live bottom regardless of how far output moved it.
    view.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
    view.advanceFrame()
    XCTAssertEqual(try linesBack(), 0, "typing must reach the live bottom and hide the indicator")

    // And it must stay hidden as the app keeps streaming (follow engaged).
    session.write(Array((200..<240).map { "line \($0)\r\n" }.joined().utf8))
    view.advanceFrame()
    let vs = try XCTUnwrap(session.viewportState())
    XCTAssertEqual(try linesBack(), 0, "after the snap, output must follow the active bottom")
    let out = TerminalScrollIndicator.decide(
      .init(
        viewportOffset: vs.viewportOffset, totalRows: vs.totalRows,
        viewportRows: vs.viewportRows, isHoverEdge: false,
        isAltScreen: vs.altScreen, isMouseTracking: vs.mouseTracking))
    XCTAssertFalse(out.shouldHold, "indicator must not hold at the live bottom")
    XCTAssertFalse(out.pillVisible, "no scrollback pill at the live bottom")
  }
}
