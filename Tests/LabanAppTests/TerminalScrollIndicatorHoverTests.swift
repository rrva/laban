import AppKit
import LabanCore
import LabanRenderer
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

  /// Performance: while the thumb is hidden at the live bottom, streaming output
  /// changes the viewport input every frame (totalRows grows) but nothing is on
  /// screen — so no Core Animation layout pass should run. Becoming visible
  /// (scrolling back) must lay out again.
  func testHiddenThumbSkipsLayoutWhileStreaming() {
    let view = TerminalScrollIndicatorView(frame: NSRect(x: 0, y: 0, width: 400, height: 600))
    view.layoutSubtreeIfNeeded()
    view.pointerInHoverZoneProbe = { false }

    // Settle at the live bottom with no hover: the thumb stays hidden.
    for total in 200...205 { applyAtBottom(view, total: total) }
    XCTAssertEqual(
      view.debugVisibility().thumbOpacity, 0, accuracy: 0.001,
      "no hover at the live bottom keeps the thumb hidden")

    let baseline = view.layoutPassCountForTesting
    for total in 206...260 { applyAtBottom(view, total: total) }
    XCTAssertEqual(
      view.layoutPassCountForTesting, baseline,
      "a hidden thumb must not lay out while streaming at the live bottom")

    // Scrolling back to the top makes the thumb visible and must lay out again.
    view.applyViewport(
      viewportOffset: 0, totalRows: 260, viewportRows: 40,
      isAltScreen: false, isMouseTracking: false)
    XCTAssertGreaterThan(
      view.layoutPassCountForTesting, baseline, "becoming visible triggers a layout pass")
    XCTAssertGreaterThan(
      view.debugVisibility().thumbOpacity, 0, "a scrolled-back thumb is visible")
  }

  /// The scrollback pill must read palette slots from `Theme.current`, not
  /// macOS system label/window colors, so it stays legible on dark themes.
  func testPillAdaptsToThemeChange() {
    let prior = Theme.current
    defer { Theme.apply(prior) }

    Theme.apply(.gruvboxDark)
    let view = TerminalScrollIndicatorView(frame: NSRect(x: 0, y: 0, width: 400, height: 600))
    view.layoutSubtreeIfNeeded()

    let chrome = view.themeChromeForTesting()
    XCTAssertEqual(chrome.pillText, Self.themedNSColor(Theme.gruvboxDark.fg0))
    XCTAssertTrue(
      Self.cgColorsEqual(
        chrome.pillBackground, Self.themedCGColor(Theme.gruvboxDark.bg2, alpha: 0.94)))
    XCTAssertTrue(
      Self.cgColorsEqual(
        chrome.pillBorder, Self.themedCGColor(Theme.gruvboxDark.dim0, alpha: 0.55)))
  }

  private static func themedNSColor(_ rgba: UInt32) -> NSColor {
    NSColor(
      red: CGFloat((rgba >> 24) & 0xFF) / 255.0,
      green: CGFloat((rgba >> 16) & 0xFF) / 255.0,
      blue: CGFloat((rgba >> 8) & 0xFF) / 255.0,
      alpha: 1)
  }

  private static func themedCGColor(_ rgba: UInt32, alpha: CGFloat) -> CGColor {
    CGColor(
      colorSpace: CGColorSpaceCreateDeviceRGB(),
      components: [
        CGFloat((rgba >> 24) & 0xFF) / 255.0,
        CGFloat((rgba >> 16) & 0xFF) / 255.0,
        CGFloat((rgba >> 8) & 0xFF) / 255.0,
        alpha,
      ])!
  }

  private static func cgColorsEqual(_ lhs: CGColor?, _ rhs: CGColor?) -> Bool {
    guard let lhs, let rhs, let lc = lhs.components, let rc = rhs.components else {
      return lhs == nil && rhs == nil
    }
    guard lc.count == rc.count else { return false }
    for i in 0..<lc.count where abs(lc[i] - rc[i]) > 0.001 { return false }
    return true
  }
}
