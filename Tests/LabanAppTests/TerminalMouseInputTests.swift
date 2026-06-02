import AppKit
import XCTest

@testable import LabanApp

final class TerminalMouseInputTests: XCTestCase {
  func testMousePositionUsesTerminalSurfacePixels() {
    let pos = TerminalMouseInput.surfacePosition(
      viewPoint: NSPoint(x: 360, y: 400),
      boundsHeight: 480,
      sidebarWidth: 200
    )

    XCTAssertEqual(pos.x, 160)
    XCTAssertEqual(pos.y, 80)
  }

  func testMouseSurfaceSizeExcludesSidebar() {
    let size = TerminalMouseInput.surfaceSize(
      boundsWidth: 1000,
      boundsHeight: 480,
      sidebarWidth: 200
    )

    XCTAssertEqual(size.width, 800)
    XCTAssertEqual(size.height, 480)
  }

  func testMouseModifiersUseGhosttyBitOrder() {
    XCTAssertEqual(TerminalMouseInput.ghosttyModifierMask(from: .shift), 1)
    XCTAssertEqual(TerminalMouseInput.ghosttyModifierMask(from: .control), 2)
    XCTAssertEqual(TerminalMouseInput.ghosttyModifierMask(from: .option), 4)
    XCTAssertEqual(TerminalMouseInput.ghosttyModifierMask(from: .command), 8)
    XCTAssertEqual(
      TerminalMouseInput.ghosttyModifierMask(from: [.shift, .control, .option, .command]),
      15
    )
  }

  func testMouseTrackingRequiresMatchingTerminalOriginButton() {
    XCTAssertEqual(
      TerminalMouseInput.trackedTerminalButton(.left, matching: .left),
      .left
    )
    XCTAssertEqual(
      TerminalMouseInput.trackedTerminalButton(.right, matching: .right),
      .right
    )
    XCTAssertNil(TerminalMouseInput.trackedTerminalButton(.none, matching: .left))
    XCTAssertNil(TerminalMouseInput.trackedTerminalButton(.left, matching: .right))
  }

  // MARK: - Left-press routing (forward to app under mouse tracking)

  func testLeftPressWithoutTrackingSelectsLocally() {
    XCTAssertEqual(
      TerminalMouseInput.leftMouseDownDisposition(mouseTracking: false, shiftHeld: false),
      .localSelection
    )
  }

  func testLeftPressUnderTrackingForwardsToApp() {
    XCTAssertEqual(
      TerminalMouseInput.leftMouseDownDisposition(mouseTracking: true, shiftHeld: false),
      .forwardToApp
    )
  }

  func testShiftAlwaysForcesLocalSelectionEvenUnderTracking() {
    XCTAssertEqual(
      TerminalMouseInput.leftMouseDownDisposition(mouseTracking: true, shiftHeld: true),
      .localSelection
    )
    XCTAssertEqual(
      TerminalMouseInput.leftMouseDownDisposition(mouseTracking: false, shiftHeld: true),
      .localSelection
    )
  }
}
