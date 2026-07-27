import CoreGraphics
import LabanRenderer
import LabanTerminalCore
import XCTest

@testable import LabanCore

/// Renderer/setting-gate coverage for the sidebar hover preview, mirroring
/// `SpinnerMotionRendererGateTests`'s shape (ADR 0030's precedent) for the
/// sibling Slug-only capability (ADR 0031). Exercises the actual gate in
/// `TerminalSurfaceController.hoverPreviewOverlayCommands` via
/// `makeFrame(...)`, not just the `SidebarProducer`-level chrome helper —
/// this is the layer where `effectiveRendererIsSlug`/`hoverPreviewEnabled`
/// are actually consulted (see execplans/active/sidebar-hover-preview.md's
/// Review Gate: this file closes the "NEEDS LIVE-APP VERIFICATION" gap the
/// first review pass found for items 5-7, which previously had no unit
/// test at this layer).
final class HoverPreviewRendererGateTests: XCTestCase {
  private func fixtureFactory(_ size: LabanTerminalSize) throws -> Session {
    try Session.fixture(size: size)
  }

  private func makeModelWithTwoTabs() throws -> (
    AppModel, activeTabId: Tab.ID, hoveredTabId: Tab.ID
  ) {
    var size = LabanTerminalSize()
    size.rows = 4
    size.cols = 20
    let model = try AppModel(initialSize: size, sessionFactory: fixtureFactory)
    let activeTab = try XCTUnwrap(model.activeTab)
    _ = try model.createTab()
    let hoveredTab = try XCTUnwrap(model.activeTab)
    model.selectTab(activeTab.id)
    let hoveredSession = try XCTUnwrap(model.session(forTab: hoveredTab.id))
    _ = hoveredSession.write(Array("background output".utf8))
    _ = hoveredSession.poll()
    return (model, activeTab.id, hoveredTab.id)
  }

  private func makeController(model: AppModel) -> TerminalSurfaceController {
    TerminalSurfaceController(
      model: model,
      cellWidth: 8,
      cellHeight: 16,
      sidebarWidth: 200,
      previewCellWidth: 4,
      previewCellHeight: 8)
  }

  private func hasPreviewCommand(_ frame: TerminalSurfaceFrame?) -> Bool {
    (frame?.commands ?? []).contains { command in
      switch command {
      case .rect(_, _, let source, _): return source == .sidebarPreview
      case .glyphRun(_, _, _, _, _, let source, _, _, _, _, _, _, _):
        return source == .sidebarPreview
      default: return false
      }
    }
  }

  /// The panel's background chrome rect (the `.replace`-composited one —
  /// see `SidebarProducer.hoverPreviewCommands`), or nil if no panel showed.
  private func previewBackgroundRect(_ frame: TerminalSurfaceFrame?) -> CGRect? {
    (frame?.commands ?? []).compactMap { command -> CGRect? in
      guard case .rect(let rect, _, let source, let compositing) = command,
        source == .sidebarPreview, compositing == .replace
      else { return nil }
      return rect
    }.first
  }

  private func sidebarRowBackground(
    _ frame: TerminalSurfaceFrame?, tabIndex: Int, viewportHeight: CGFloat = 600
  ) -> UInt32? {
    let rowHeight = SidebarProducer(sidebarWidth: 200, cellWidth: 8, cellHeight: 16).rowHeight
    let expectedY = viewportHeight - CGFloat(tabIndex + 1) * rowHeight
    return (frame?.commands ?? []).compactMap { command -> UInt32? in
      guard case .rect(let rect, let color, let source, _) = command,
        source == .sidebar,
        rect.width == 200,
        rect.height == rowHeight,
        abs(rect.minY - expectedY) < 0.01
      else { return nil }
      return color
    }.first
  }

  private func makeFrame(
    controller: TerminalSurfaceController,
    hoveredTabId: Tab.ID?,
    isKeyboardPeek: Bool = false,
    effectiveRendererIsSlug: Bool,
    hoverPreviewEnabled: Bool
  ) -> TerminalSurfaceFrame? {
    controller.makeFrame(
      TerminalSurfaceFrameRequest(
        frame: 1,
        viewportWidth: 800,
        viewportHeight: 600,
        hoveredSidebarTabId: hoveredTabId,
        hoveredSidebarTabIdIsKeyboardPeek: isKeyboardPeek,
        requireActiveSnapshot: false,
        surfaceWidth: 800,
        surfaceHeight: 600,
        surfaceScale: 1,
        effectiveRendererIsSlug: effectiveRendererIsSlug,
        hoverPreviewEnabled: hoverPreviewEnabled))
  }

  /// Positive control: proves the other three tests aren't vacuously
  /// passing by confirming the eligible combination actually emits
  /// `.sidebarPreview` commands.
  func testEligibleSlugWithSettingOnEmitsPreviewCommands() throws {
    let (model, _, hoveredTabId) = try makeModelWithTwoTabs()
    let controller = makeController(model: model)
    let frame = makeFrame(
      controller: controller, hoveredTabId: hoveredTabId,
      effectiveRendererIsSlug: true, hoverPreviewEnabled: true)
    XCTAssertTrue(
      hasPreviewCommand(frame),
      "Slug renderer + setting on + hovering a background tab must show the preview")
  }

  func testNonSlugRendererSuppressesPreviewEvenWithSettingOn() throws {
    let (model, _, hoveredTabId) = try makeModelWithTwoTabs()
    let controller = makeController(model: model)
    let frame = makeFrame(
      controller: controller, hoveredTabId: hoveredTabId,
      effectiveRendererIsSlug: false, hoverPreviewEnabled: true)
    XCTAssertFalse(
      hasPreviewCommand(frame),
      "the Slug-only gate must hold even when the setting is on (ADR 0031)")
  }

  func testSettingOffSuppressesPreviewEvenOnSlug() throws {
    let (model, _, hoveredTabId) = try makeModelWithTwoTabs()
    let controller = makeController(model: model)
    let frame = makeFrame(
      controller: controller, hoveredTabId: hoveredTabId,
      effectiveRendererIsSlug: true, hoverPreviewEnabled: false)
    XCTAssertFalse(
      hasPreviewCommand(frame),
      "the setting gate must hold independent of renderer eligibility")
  }

  func testHoveringActiveTabsOwnRowSuppressesPreview() throws {
    let (model, activeTabId, _) = try makeModelWithTwoTabs()
    let controller = makeController(model: model)
    let frame = makeFrame(
      controller: controller, hoveredTabId: activeTabId,
      effectiveRendererIsSlug: true, hoverPreviewEnabled: true)
    XCTAssertFalse(
      hasPreviewCommand(frame),
      "the active tab's own row must never show a preview of itself")
  }

  func testKeyboardCycleCanPreviewTheAlreadyActiveTab() throws {
    let (model, activeTabId, _) = try makeModelWithTwoTabs()
    let controller = makeController(model: model)
    let frame = makeFrame(
      controller: controller, hoveredTabId: activeTabId, isKeyboardPeek: true,
      effectiveRendererIsSlug: true, hoverPreviewEnabled: true)

    XCTAssertTrue(
      hasPreviewCommand(frame),
      "the active tab is suppressed for mouse hover but must remain a keyboard-cycle preview stop")
  }

  func testKeyboardPeekHighlightsTentativeDestinationWithoutChangingMouseHoverStyling() throws {
    let (model, _, hoveredTabId) = try makeModelWithTwoTabs()
    let controller = makeController(model: model)

    let mouseFrame = makeFrame(
      controller: controller, hoveredTabId: hoveredTabId, isKeyboardPeek: false,
      effectiveRendererIsSlug: true, hoverPreviewEnabled: true)
    let keyboardFrame = makeFrame(
      controller: controller, hoveredTabId: hoveredTabId, isKeyboardPeek: true,
      effectiveRendererIsSlug: true, hoverPreviewEnabled: true)

    XCTAssertEqual(
      sidebarRowBackground(mouseFrame, tabIndex: 0), Theme.current.bg2,
      "ordinary mouse hover must leave the committed active row highlighted")
    XCTAssertEqual(
      sidebarRowBackground(mouseFrame, tabIndex: 1), Theme.current.bg1,
      "ordinary mouse hover must not make the hovered row look selected")
    XCTAssertEqual(
      sidebarRowBackground(keyboardFrame, tabIndex: 0), Theme.current.bg1,
      "while peeking, the committed row yields the selected styling to the tentative target")
    XCTAssertEqual(
      sidebarRowBackground(keyboardFrame, tabIndex: 1), Theme.current.bg2,
      "the tab that modifier release would commit must already be highlighted")
  }

  func testKeyboardPeekHighlightObeysRendererAndSettingGates() throws {
    let (model, _, hoveredTabId) = try makeModelWithTwoTabs()
    let controller = makeController(model: model)

    let rendererDisabledFrame = makeFrame(
      controller: controller, hoveredTabId: hoveredTabId, isKeyboardPeek: true,
      effectiveRendererIsSlug: false, hoverPreviewEnabled: true)
    let settingDisabledFrame = makeFrame(
      controller: controller, hoveredTabId: hoveredTabId, isKeyboardPeek: true,
      effectiveRendererIsSlug: true, hoverPreviewEnabled: false)

    for frame in [rendererDisabledFrame, settingDisabledFrame] {
      XCTAssertEqual(
        sidebarRowBackground(frame, tabIndex: 0), Theme.current.bg2,
        "an ineligible preview must keep the committed tab highlighted")
      XCTAssertEqual(
        sidebarRowBackground(frame, tabIndex: 1), Theme.current.bg1,
        "an ineligible tentative target must retain ordinary row styling")
    }
  }

  func testMissingKeyboardPeekTargetKeepsCommittedSelectionVisible() throws {
    let (model, _, _) = try makeModelWithTwoTabs()
    let controller = makeController(model: model)

    let frame = makeFrame(
      controller: controller,
      hoveredTabId: "closed-tab",
      isKeyboardPeek: true,
      effectiveRendererIsSlug: true,
      hoverPreviewEnabled: true)

    XCTAssertEqual(
      sidebarRowBackground(frame, tabIndex: 0), Theme.current.bg2,
      "a closed tentative target must fall back to the committed active row")
    XCTAssertFalse(hasPreviewCommand(frame))
  }

  /// Keyboard hold-to-peek (`hoveredSidebarTabIdIsKeyboardPeek`) must center
  /// the panel in the terminal pane rather than beside the hovered row —
  /// there is no cursor position to anchor beside during a keyboard switch,
  /// and the user is looking at the terminal pane they're about to land in.
  func testKeyboardPeekCentersPanelInsteadOfPlacingItBesideTheRow() throws {
    let (model, _, hoveredTabId) = try makeModelWithTwoTabs()
    let controller = makeController(model: model)

    let mouseFrame = makeFrame(
      controller: controller, hoveredTabId: hoveredTabId, isKeyboardPeek: false,
      effectiveRendererIsSlug: true, hoverPreviewEnabled: true)
    let keyboardFrame = makeFrame(
      controller: controller, hoveredTabId: hoveredTabId, isKeyboardPeek: true,
      effectiveRendererIsSlug: true, hoverPreviewEnabled: true)

    let besideRowRect = try XCTUnwrap(
      previewBackgroundRect(mouseFrame), "mouse hover must still show the panel beside the row")
    let centeredRect = try XCTUnwrap(
      previewBackgroundRect(keyboardFrame), "keyboard peek must still show the panel")

    XCTAssertEqual(
      besideRowRect.size, centeredRect.size,
      "centering must reposition the panel, not resize it")
    XCTAssertNotEqual(
      besideRowRect.origin, centeredRect.origin,
      "keyboard peek must not sit in the same place as the mouse-hover panel")

    let paneMidX = 200 + (800 - 200) / 2.0
    XCTAssertEqual(
      centeredRect.midX, paneMidX, accuracy: 0.01,
      "keyboard peek must be horizontally centered in the terminal pane (right of the sidebar)")
    XCTAssertEqual(
      centeredRect.midY, 300, accuracy: 0.01,
      "keyboard peek must be vertically centered in the terminal pane")
  }
}
