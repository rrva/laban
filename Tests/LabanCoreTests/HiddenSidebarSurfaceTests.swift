import CoreGraphics
import Foundation
import LabanRenderer
import LabanTerminalCore
import XCTest

@testable import LabanCore

/// Switching the tab sidebar off (`SidebarVisibilitySettings`) sets its width to
/// zero. Zero width is the entire mechanism: the command builder emits nothing,
/// and at the call sites in `TerminalBitmapView` every hit test
/// (`pt.x < sidebarWidth`) stops matching while the terminal's column count
/// (`termW = w - sidebarWidth …`) grows by the reclaimed strip.
final class HiddenSidebarSurfaceTests: XCTestCase {

  private func makeController(sidebarWidth: CGFloat) throws -> (TerminalSurfaceController, Tab.ID) {
    var size = LabanTerminalSize()
    size.rows = 4
    size.cols = 20
    let model = try AppModel(initialSize: size)
    let controller = TerminalSurfaceController(
      model: model, cellWidth: 8, cellHeight: 16, sidebarWidth: sidebarWidth)
    return (controller, model.tabs[0].id)
  }

  func testVisibleSidebarEmitsChrome() throws {
    let (controller, tabId) = try makeController(sidebarWidth: 200)
    let commands = controller.sidebarCommands(activeTabId: tabId, viewportHeight: 200)
    XCTAssertFalse(commands.isEmpty, "a sidebar with width must draw itself")
  }

  func testHiddenSidebarEmitsNothing() throws {
    let (controller, tabId) = try makeController(sidebarWidth: 0)
    XCTAssertTrue(controller.sidebarCommands(activeTabId: tabId, viewportHeight: 200).isEmpty)
  }

  /// The guard must short-circuit before the producer runs, so a hidden sidebar
  /// costs nothing per frame rather than building a zero-width panel and
  /// throwing it away.
  func testHiddenSidebarDoesNotBuild() throws {
    let (controller, tabId) = try makeController(sidebarWidth: 0)
    _ = controller.sidebarCommands(activeTabId: tabId, viewportHeight: 200)
    _ = controller.sidebarCommands(activeTabId: tabId, viewportHeight: 400)
    XCTAssertEqual(controller.sidebarRebuildCountForTesting, 0)
  }

  /// Toggling at runtime must take effect on the next frame, not at the next
  /// relaunch — the view updates `surfaceController.sidebarWidth` when the
  /// setting changes.
  func testWidthChangeTakesEffectImmediately() throws {
    let (controller, tabId) = try makeController(sidebarWidth: 200)
    XCTAssertFalse(controller.sidebarCommands(activeTabId: tabId, viewportHeight: 200).isEmpty)
    controller.sidebarWidth = 0
    XCTAssertTrue(controller.sidebarCommands(activeTabId: tabId, viewportHeight: 200).isEmpty)
    controller.sidebarWidth = 200
    XCTAssertFalse(controller.sidebarCommands(activeTabId: tabId, viewportHeight: 200).isEmpty)
  }

  /// The terminal grid claims the reclaimed strip: the same window is wider in
  /// columns with the sidebar off. This is the arithmetic `setFrameSize` runs.
  func testTerminalReclaimsTheSidebarStrip() {
    let windowWidth = 1200
    let cellWidth = 8
    func columns(sidebar: CGFloat) -> Int {
      max(1, (windowWidth - Int(sidebar)) / cellWidth)
    }
    let shown = columns(sidebar: SidebarVisibilitySettings.effectiveWidth(200, visible: true))
    let hidden = columns(sidebar: SidebarVisibilitySettings.effectiveWidth(200, visible: false))
    XCTAssertEqual(hidden - shown, 200 / cellWidth)
  }
}
