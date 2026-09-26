import Foundation
import LabanCore
import LabanTerminalCore
import XCTest

@testable import LabanApp

/// The size sessions start with, before the view's first resize. A restart
/// reattach replays the labpty byte ring into a session of this size.
final class InitialTerminalSizeTests: XCTestCase {
  override func setUp() {
    super.setUp()
    laban_set_kitty_graphics_enabled(true)
  }

  override func tearDown() {
    laban_set_kitty_graphics_enabled(false)
    super.tearDown()
  }

  func testReplayedKittyImageSpansTheSameRowsAsItDidLive() throws {
    let size = MainWindowController.initialTerminalSize(
      viewWidth: 1200, viewHeight: 800, sidebarWidth: 0, cellWidth: 10, cellHeight: 20)
    XCTAssertEqual(size.cell_width, 10)
    XCTAssertEqual(size.cell_height, 20)

    // An 8x70 px image with no `r=` spans ceil(70 / 20) = 4 rows, and the
    // cursor moves below it, so the caption after it lands 4 rows down.
    let pixels = Data(repeating: 0xFF, count: 8 * 70 * 4).base64EncodedString()
    let output = Array(
      "top\r\n\u{1b}_Ga=T,f=32,s=8,v=70,q=2;\(pixels)\u{1b}\\\r\nafter".utf8)

    // Live: the view has resized the session to the window before output.
    let live = try Session.parserOnly(size: size)
    _ = live.resize(size)
    _ = live.feedOutput(output)
    // Restart: the byte-ring replay reaches a session straight from creation.
    let replayed = try Session.parserOnly(size: size)
    _ = replayed.feedOutput(output)

    let liveCursor = try cursor(of: live)
    XCTAssertEqual(liveCursor.row, 5, "precondition: the image pushed the caption 4 rows down")
    let replayedCursor = try cursor(of: replayed)
    XCTAssertEqual(
      replayedCursor.row, liveCursor.row,
      """
      replaying into a freshly created session must place text after a Kitty \
      image on the same row as live output did; a session without cell pixel \
      geometry sizes the image to zero rows and the text slides under it
      """)
    XCTAssertEqual(replayedCursor.placements, 1)
  }

  private func cursor(of session: Session) throws -> (row: Int, placements: Int) {
    let snapshot = try XCTUnwrap(session.snapshot())
    defer { laban_snapshot_destroy(snapshot) }
    return (Int(snapshot.pointee.cursor_row), snapshot.pointee.image_placement_count)
  }
}
