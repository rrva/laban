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

  private func makeFrame(
    controller: TerminalSurfaceController,
    hoveredTabId: Tab.ID?,
    effectiveRendererIsSlug: Bool,
    hoverPreviewEnabled: Bool
  ) -> TerminalSurfaceFrame? {
    controller.makeFrame(
      TerminalSurfaceFrameRequest(
        frame: 1,
        viewportWidth: 800,
        viewportHeight: 600,
        hoveredSidebarTabId: hoveredTabId,
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
}
