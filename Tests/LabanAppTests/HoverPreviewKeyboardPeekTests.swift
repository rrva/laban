import AppKit
import LabanCore
import LabanRenderer
import LabanTerminalCore
import XCTest

@testable import LabanApp

/// Coverage for the keyboard hold-to-peek gesture (Ctrl+Tab, Cmd+Option+←/→,
/// Cmd+Shift+[/]): holding one of these should preview the tab you'd land
/// on without committing, and release should commit — mirroring macOS's own
/// Cmd+Tab app-switcher. `TerminalBitmapView.beginOrAdvancePeek(delta:triggerModifiers:)`
/// and `.commitPeek(tabId:)` are exercised DIRECTLY (their access level was
/// loosened from `private` for exactly this) rather than through a
/// synthetic `NSEvent`-driven `keyDown`/`flagsChanged` dispatch: this test
/// target has no existing precedent anywhere for simulating those AppKit
/// event types (confirmed by search before writing this file), and
/// building that simulation infrastructure from scratch was judged
/// disproportionate to this one feature — the same call made for the
/// keyboard hover-clear fix earlier in this plan.
///
/// `executeAppCommand` itself (also loosened from `private`) DOES have real
/// branching logic worth exercising directly: `.selectNextTab`/
/// `.selectPreviousTab` only hold-to-peek when
/// `hoverPreviewEffectivelyEnabled` (setting on AND effective renderer is
/// Slug) — otherwise they must fall back to the original instant
/// `selectRelativeTab(delta:)`, exactly as they did before this gesture
/// existed. An external review caught this: the first cut called
/// `beginOrAdvancePeek` unconditionally, so with the setting at its default
/// (off) or any non-Slug renderer, Ctrl+Tab/Cmd+Option+←/→ stopped switching
/// tabs immediately for every user who couldn't see the peek panel at all —
/// deferred navigation with zero visual feedback. This test target has no
/// precedent for constructing a Slug-backed `TerminalBitmapView` (GPU/Metal
/// dependency, unlike `LabanRendererTests`), so only the not-effectively-
/// enabled branch is covered here; the peek branch itself is covered by the
/// other tests in this file plus `HoverPreviewRendererGateTests` at the
/// `TerminalSurfaceController` layer.
final class HoverPreviewKeyboardPeekTests: XCTestCase {
  private struct Harness {
    let model: AppModel
    let view: TerminalBitmapView
    let oldRenderer: String?

    func restoreRenderer() {
      if let oldRenderer {
        setenv("LABAN_RENDERER", oldRenderer, 1)
      } else {
        unsetenv("LABAN_RENDERER")
      }
    }
  }

  private func makeHarness(tabCount: Int) throws -> Harness {
    let oldRenderer = getenv("LABAN_RENDERER").map { String(cString: $0) }
    setenv("LABAN_RENDERER", "software", 1)

    var size = LabanTerminalSize()
    size.rows = 5
    size.cols = 20
    let model = try AppModel(initialSize: size) { try Session.fixture(size: $0) }
    for _ in 1..<tabCount {
      _ = try model.createTab()
    }
    model.selectTab(model.tabs[0].id)

    let fontAtlas = FontAtlas(pointSize: 14)
    let sidebarFontAtlas = FontAtlas(pointSize: 11)
    let cellSize = fontAtlas.cellSize
    let view = TerminalBitmapView(
      model: model,
      fontAtlas: fontAtlas,
      sidebarFontAtlas: sidebarFontAtlas,
      cellWidth: Int(cellSize.width),
      cellHeight: Int(cellSize.height)
    )
    view.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
    return Harness(model: model, view: view, oldRenderer: oldRenderer)
  }

  func testHoverPreviewShowingRequiresMatchingRenderedPanel() {
    XCTAssertTrue(
      TerminalBitmapView.hoverPreviewShowing(
        eligibleTabId: "tab-2",
        renderedTabId: "tab-2"))
    XCTAssertFalse(
      TerminalBitmapView.hoverPreviewShowing(
        eligibleTabId: "tab-2",
        renderedTabId: nil),
      "eligibility without commands must not claim that a failed remote preview is visible")
    XCTAssertFalse(
      TerminalBitmapView.hoverPreviewShowing(
        eligibleTabId: "tab-3",
        renderedTabId: "tab-2"),
      "a stale completed panel for another target is not the current preview")
  }

  func testAdvancingPeekTwiceDoesNotCommitUntilReleased() throws {
    let harness = try makeHarness(tabCount: 3)
    defer { harness.restoreRenderer() }
    let tabs = harness.model.tabs
    let startId = try XCTUnwrap(harness.model.activeTab?.id)
    XCTAssertEqual(startId, tabs[0].id)

    harness.view.beginOrAdvancePeek(delta: 1, triggerModifiers: [.control])
    XCTAssertEqual(harness.view.peekedSidebarTabId, tabs[1].id)
    XCTAssertEqual(
      harness.model.activeTab?.id, startId,
      "a single peek step must not commit the tab switch")

    harness.view.beginOrAdvancePeek(delta: 1, triggerModifiers: [.control])
    XCTAssertEqual(
      harness.view.peekedSidebarTabId, tabs[2].id,
      "a second peek step must advance from the PEEKED tab, not re-derive from the active one")
    XCTAssertEqual(
      harness.model.activeTab?.id, startId,
      "still must not commit while the chord is conceptually held")
  }

  func testCommitPeekActivatesTheTabAndClearsPeekState() throws {
    let harness = try makeHarness(tabCount: 3)
    defer { harness.restoreRenderer() }
    let tabs = harness.model.tabs

    harness.view.beginOrAdvancePeek(delta: 1, triggerModifiers: [.control])
    harness.view.beginOrAdvancePeek(delta: 1, triggerModifiers: [.control])
    let peeked = try XCTUnwrap(harness.view.peekedSidebarTabId)
    XCTAssertEqual(peeked, tabs[2].id)

    harness.view.commitPeek(tabId: peeked)
    XCTAssertEqual(
      harness.model.activeTab?.id, tabs[2].id,
      "releasing the chord must commit to whichever tab was last peeked")
    XCTAssertNil(
      harness.view.peekedSidebarTabId, "committing must clear the peek so it can't linger")
  }

  func testCommitPeekWithNilTabIdIsANoOp() throws {
    let harness = try makeHarness(tabCount: 2)
    defer { harness.restoreRenderer() }
    let startId = try XCTUnwrap(harness.model.activeTab?.id)

    harness.view.commitPeek(tabId: nil)
    XCTAssertEqual(
      harness.model.activeTab?.id, startId,
      "flagsChanged firing with no peek in progress must not change the active tab")
  }

  func testClosedPeekTargetClearsAndNextCycleRecoversFromActiveTab() throws {
    let harness = try makeHarness(tabCount: 3)
    defer { harness.restoreRenderer() }
    let activeId = try XCTUnwrap(harness.model.activeTab?.id)

    harness.view.beginOrAdvancePeek(delta: 1, triggerModifiers: [.control])
    let closedTarget = try XCTUnwrap(harness.view.peekedSidebarTabId)
    try harness.model.closeTab(closedTarget)

    harness.view.commitPeek(tabId: closedTarget)
    XCTAssertNil(harness.view.peekedSidebarTabId)
    XCTAssertEqual(
      harness.model.activeTab?.id, activeId,
      "releasing after the tentative tab closes must keep the committed tab")

    harness.view.beginOrAdvancePeek(delta: 1, triggerModifiers: [.control])
    XCTAssertNotNil(
      harness.view.peekedSidebarTabId,
      "the next cycle must restart from the active tab rather than the vanished target")
    XCTAssertNotEqual(harness.view.peekedSidebarTabId, closedTarget)
  }

  func testClosedOffscreenPeekTargetRestoresActiveRowVisibility() throws {
    let harness = try makeHarness(tabCount: 20)
    defer { harness.restoreRenderer() }
    harness.view.frame = NSRect(x: 0, y: 0, width: 400, height: 100)
    let activeId = try XCTUnwrap(harness.model.activeTab?.id)

    for _ in 0..<12 {
      harness.view.beginOrAdvancePeek(delta: 1, triggerModifiers: [.control])
    }
    let closedTarget = try XCTUnwrap(harness.view.peekedSidebarTabId)
    XCTAssertGreaterThan(harness.view.sidebarScrollOffsetForTesting, 0)
    try harness.model.closeTab(closedTarget)

    harness.view.commitPeek(tabId: closedTarget)

    XCTAssertEqual(harness.model.activeTab?.id, activeId)
    XCTAssertEqual(
      harness.view.sidebarScrollOffsetForTesting,
      0,
      accuracy: 0.001,
      "releasing after the off-screen target vanished must reveal the committed row")
  }

  func testPeekWrapsAroundTabList() throws {
    let harness = try makeHarness(tabCount: 3)
    defer { harness.restoreRenderer() }
    let tabs = harness.model.tabs

    // Backward from the first tab must wrap to the last.
    harness.view.beginOrAdvancePeek(delta: -1, triggerModifiers: [.control, .shift])
    XCTAssertEqual(harness.view.peekedSidebarTabId, tabs[2].id)
  }

  func testPeekCycleIncludesInitiallyActiveTabBeforeStartingAnotherLap() throws {
    let harness = try makeHarness(tabCount: 3)
    defer { harness.restoreRenderer() }
    let tabs = harness.model.tabs
    let startId = try XCTUnwrap(harness.model.activeTab?.id)

    harness.view.beginOrAdvancePeek(delta: 1, triggerModifiers: [.control])
    harness.view.beginOrAdvancePeek(delta: 1, triggerModifiers: [.control])
    harness.view.beginOrAdvancePeek(delta: 1, triggerModifiers: [.control])

    XCTAssertEqual(
      harness.view.peekedSidebarTabId, tabs[0].id,
      "the already-active tab must be a real stop in the keyboard preview cycle")
    XCTAssertEqual(
      harness.model.activeTab?.id, startId,
      "cycling back to the active tab still must not commit before modifier release")

    harness.view.beginOrAdvancePeek(delta: 1, triggerModifiers: [.control])
    XCTAssertEqual(
      harness.view.peekedSidebarTabId, tabs[1].id,
      "the next keypress after previewing the active tab must begin the next lap")
  }

  func testKeyboardPeekImmediatelyScrollsOffscreenDestinationIntoSidebar() throws {
    let harness = try makeHarness(tabCount: 20)
    defer { harness.restoreRenderer() }
    harness.view.frame = NSRect(x: 0, y: 0, width: 400, height: 100)

    for _ in 0..<12 {
      harness.view.beginOrAdvancePeek(delta: 1, triggerModifiers: [.control])
    }

    XCTAssertEqual(harness.view.peekedSidebarTabId, harness.model.tabs[12].id)
    XCTAssertGreaterThan(
      harness.view.sidebarScrollOffsetForTesting,
      0,
      "tentative selection must be scrolled into view before the modifier is released")
    XCTAssertEqual(
      harness.model.activeTab?.id,
      harness.model.tabs[0].id,
      "making the preview target visible must not commit the tab selection")
  }

  func testTabCycleCommandInstantSwitchesWhenHoverPreviewNotEffectivelyEnabled() throws {
    // makeHarness forces LABAN_RENDERER=software, so `backend is
    // SlugGlyphRenderer` is false regardless of HoverPreviewSettings.enabled
    // — hoverPreviewEffectivelyEnabled is false no matter what the setting
    // says, matching every non-Slug user's actual configuration.
    let harness = try makeHarness(tabCount: 3)
    defer { harness.restoreRenderer() }
    let tabs = harness.model.tabs
    let startId = try XCTUnwrap(harness.model.activeTab?.id)
    XCTAssertEqual(startId, tabs[0].id)

    harness.view.executeAppCommand(.selectNextTab, triggerModifiers: [.control])

    XCTAssertEqual(
      harness.model.activeTab?.id, tabs[1].id,
      "without an eligible renderer/setting, the chord must switch tabs immediately, "
        + "exactly as it did before hold-to-peek existed")
    XCTAssertNil(
      harness.view.peekedSidebarTabId,
      "must never enter peek state when the panel could never be shown")
  }
}
