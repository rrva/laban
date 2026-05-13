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

    let event = try XCTUnwrap(
      CGEvent(
        scrollWheelEvent2Source: nil,
        units: .line,
        wheelCount: 1,
        wheel1: 4,
        wheel2: 0,
        wheel3: 0
      ))
    event.location = CGPoint(x: SidebarLayout.defaultWidth + 50, y: 50)
    view.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: event)))

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
}
