import AppKit
import LabanCore
import XCTest

@testable import LabanApp

/// Regression: the overlay scroll indicator stuck visible at the live bottom.
///
/// Root cause (found via live on-instance instrumentation, not the scroll
/// path): the viewport followed the live bottom correctly (`linesBack == 0`),
/// but the indicator's `isHoverEdge` flag was pinned true. AppKit drops a
/// `mouseExited` when the right-edge tracking area is rebuilt with the pointer
/// inside (among other races), so the flag never cleared. With `linesBack == 0`,
/// `decide()` still returns `shouldHold = isHoverEdge`, so a stale hover held
/// the thumb at full opacity until the next genuine enter/exit or window
/// unfocus (`.activeInKeyWindow` emits an exit on resignKey — which is exactly
/// why the bug "fixed itself" when the window lost focus).
///
/// The view now re-validates hover against the live pointer location on each
/// frame sample and clears a stale flag.
final class TerminalScrollIndicatorHoverTests: XCTestCase {

  /// Viewport pinned to the live bottom: bottom offset is `total - viewportRows`,
  /// so `linesBack == 0`, with enough total rows that the indicator is eligible
  /// to show (total > viewportRows).
  private func applyAtBottom(_ view: TerminalScrollIndicatorView, total: Int) {
    view.applyViewport(
      viewportOffset: total - 40, totalRows: total, viewportRows: 40,
      isAltScreen: false, isMouseTracking: false)
  }

  private func synthEnter() -> NSEvent {
    NSEvent.enterExitEvent(
      with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
      windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!
  }

  func testStaleHoverIsClearedAtLiveBottom() {
    let view = TerminalScrollIndicatorView(frame: NSRect(x: 0, y: 0, width: 400, height: 600))
    view.layoutSubtreeIfNeeded()

    // Pointer genuinely in the right-edge zone: hover-reveal holds the thumb at
    // the bottom (the intended affordance).
    view.pointerInHoverZoneProbe = { true }
    view.mouseEntered(with: synthEnter())
    applyAtBottom(view, total: 200)

    var vis = view.debugVisibility()
    XCTAssertTrue(vis.isHoverEdge, "mouseEntered sets the hover flag")
    XCTAssertTrue(vis.shouldHold, "a genuine edge hover holds the thumb at the bottom")
    XCTAssertGreaterThan(vis.thumbOpacity, 0, "thumb is visible while genuinely hovered")

    // The pointer has left the zone but no mouseExited arrived (the dropped-exit
    // race). The next frame sample must clear the stale hover instead of pinning
    // the thumb on at the live bottom. Total changes so applyViewport does not
    // short-circuit on an unchanged input.
    view.pointerInHoverZoneProbe = { false }
    applyAtBottom(view, total: 201)

    vis = view.debugVisibility()
    XCTAssertFalse(vis.isHoverEdge, "a stale hover must clear once the pointer leaves the zone")
    XCTAssertFalse(
      vis.shouldHold, "the indicator must not hold at the live bottom without a genuine hover")
  }

  /// The fix must not clear a *live* hover: while the pointer is genuinely in the
  /// zone, the hover reveal keeps holding the thumb even at the live bottom.
  func testGenuineHoverIsPreservedAtLiveBottom() {
    let view = TerminalScrollIndicatorView(frame: NSRect(x: 0, y: 0, width: 400, height: 600))
    view.layoutSubtreeIfNeeded()
    view.pointerInHoverZoneProbe = { true }
    view.mouseEntered(with: synthEnter())
    applyAtBottom(view, total: 200)
    applyAtBottom(view, total: 201)

    let vis = view.debugVisibility()
    XCTAssertTrue(vis.isHoverEdge, "a live edge hover persists across frames")
    XCTAssertTrue(vis.shouldHold, "hover-reveal holds the thumb at the bottom")
  }
}
