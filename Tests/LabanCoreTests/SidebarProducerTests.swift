import CoreGraphics
import Foundation
import LabanRenderer
import XCTest

@testable import LabanCore

final class SidebarProducerTests: XCTestCase {

  private func makeTabs(count: Int) -> [Tab] {
    (0..<count).map { i in
      Tab(
        id: "tab-\(i)",
        position: i + 1,
        title: "Tab \(i + 1)",
        isActive: i == 0,
        sessionId: "session-\(i)"
      )
    }
  }

  func testCommandsAreNonEmpty() {
    let tabs = makeTabs(count: 2)
    let p = SidebarProducer(sidebarWidth: 320, cellWidth: 8, cellHeight: 16)
    let cmds = p.commands(tabs: tabs, activeTabId: tabs[0].id, height: 600)
    XCTAssertFalse(cmds.isEmpty)
  }

  func testAllCommandsHaveSidebarSource() {
    let tabs = makeTabs(count: 3)
    let p = SidebarProducer(sidebarWidth: 320, cellWidth: 8, cellHeight: 16)
    let cmds = p.commands(tabs: tabs, activeTabId: tabs[1].id, height: 600)
    for cmd in cmds {
      switch cmd {
      case .rect(_, _, let src, _):
        XCTAssertEqual(src, .sidebar, "rect must have sidebar source")
      case .glyphRun(_, _, _, _, _, let src, _, _, _, _, _):
        XCTAssertEqual(src, .sidebar, "glyphRun must have sidebar source")
      default:
        XCTFail("unexpected command type: \(cmd)")
      }
    }
  }

  func testBackgroundRectCoversFullHeight() {
    let p = SidebarProducer(sidebarWidth: 320, cellWidth: 8, cellHeight: 16)
    let cmds = p.commands(tabs: [], activeTabId: nil, height: 800)
    let bgRect = cmds.compactMap { cmd -> CGRect? in
      if case .rect(let r, _, _, _) = cmd { return r }
      return nil
    }.first
    XCTAssertNotNil(bgRect)
    XCTAssertEqual(bgRect!.height, 800, accuracy: 0.5)
    XCTAssertEqual(bgRect!.width, p.sidebarWidth, accuracy: 0.5)
  }

  func testActiveTabProducesMoreRectsThanInactive() {
    let tabs = makeTabs(count: 2)
    let p = SidebarProducer(sidebarWidth: 200, cellWidth: 8, cellHeight: 16)

    let cmdsActiveFirst = p.commands(tabs: tabs, activeTabId: tabs[0].id, height: 600)
    let cmdsActiveSecond = p.commands(tabs: tabs, activeTabId: tabs[1].id, height: 600)

    // Active tab emits an extra stripe rect; total rect count should differ
    let rectCount0 = cmdsActiveFirst.filter {
      if case .rect = $0 { return true }
      return false
    }.count
    let rectCount1 = cmdsActiveSecond.filter {
      if case .rect = $0 { return true }
      return false
    }.count
    XCTAssertEqual(
      rectCount0, rectCount1, "rect count must be the same regardless of which tab is active")
  }

  func testTabPositionsRenderAsDimGutter() {
    let tabs = makeTabs(count: 3)
    let p = SidebarProducer(sidebarWidth: 200, cellWidth: 8, cellHeight: 16)
    let cmds = p.commands(tabs: tabs, activeTabId: tabs[0].id, height: 600)
    let runs = cmds.compactMap { cmd -> (CGPoint, String, UInt32)? in
      if case .glyphRun(let origin, let text, let fg, _, _, _, _, _, _, _, _) = cmd {
        return (origin, text, fg)
      }
      return nil
    }
    for tab in tabs {
      let index = "\(tab.position)"
      let title = "Tab \(tab.position)"
      guard let indexRun = runs.first(where: { $0.1 == index }),
        let titleRun = runs.first(where: { $0.1 == title })
      else {
        XCTFail("expected gutter index and title for \(title); got \(runs.map(\.1))")
        continue
      }
      XCTAssertEqual(indexRun.2, Theme.current.dim0)
      XCTAssertEqual(titleRun.0.x, indexRun.0.x + 3 * p.cellWidth, accuracy: 0.001)
    }
  }

  // MARK: - hitTest

  func testHitTestEmptySidebarTopReturnsNone() {
    // The "+" button moved to a titlebar accessory — clicking the top of
    // an empty sidebar no longer creates a tab. With no tabs present the
    // entire sidebar should hit nothing.
    let p = SidebarProducer(sidebarWidth: 200, cellWidth: 8, cellHeight: 16)
    let h: CGFloat = 600
    let topY = h - p.rowHeight / 2
    let result = p.hitTest(at: CGPoint(x: 50, y: topY), tabs: [], height: h)
    XCTAssertEqual(result, .none)
  }

  func testHitTestSelectTab() {
    let tabs = makeTabs(count: 2)
    let p = SidebarProducer(sidebarWidth: 200, cellWidth: 8, cellHeight: 16)
    let h: CGFloat = 600
    // Tab 0 is now the topmost row (no "+" slot above it).
    let tabY = h - p.rowHeight + p.rowHeight / 2
    let result = p.hitTest(at: CGPoint(x: 50, y: tabY), tabs: tabs, height: h)
    XCTAssertEqual(result, .selectTab(tabs[0].id))
  }

  func testHitTestCloseTab() {
    let tabs = makeTabs(count: 1)
    let p = SidebarProducer(sidebarWidth: 200, cellWidth: 8, cellHeight: 16)
    let h: CGFloat = 600
    // Close glyph zone sits in the top band of the (quad-height) tab row.
    // Click within that band on the right edge.
    let tabBottomY = h - p.rowHeight
    let titleBandY = tabBottomY + p.rowHeight - 8  // a few pt below row top
    let result = p.hitTest(at: CGPoint(x: 190, y: titleBandY), tabs: tabs, height: h)
    XCTAssertEqual(result, .closeTab(tabs[0].id))
  }

  func testHitTestCloseTabOnSparseFreshTab() {
    // A freshly started tab has no info lines, so the title (and therefore
    // the hover X) is centered vertically in the row — below the midpoint.
    // The close box must still cover the glyph; previously only the upper
    // half of the row closed, so clicks on the lower portion of the X
    // selected the tab instead.
    let tabs = makeTabs(count: 1)
    let p = SidebarProducer(sidebarWidth: 200, cellWidth: 8, cellHeight: 16)
    let h: CGFloat = 600
    let tabBottomY = h - p.rowHeight
    let titleBaselineY = tabBottomY + (p.rowHeight - p.cellHeight) / 2
    let result = p.hitTest(at: CGPoint(x: 190, y: titleBaselineY), tabs: tabs, height: h)
    XCTAssertEqual(result, .closeTab(tabs[0].id))
  }

  func testHitTestCloseTabOnPopulatedTab() {
    // With info lines the title/close glyph moves up; the hit target must
    // follow it rather than staying low and swallowing metadata-line clicks.
    var tab = Tab(id: "t", position: 1, title: "auth", isActive: false, sessionId: "s")
    tab.titleMetadata.workspace = TabWorkspaceMetadata(
      repoName: "laban", worktreeName: "cobra", branch: "main", isDirty: true)
    tab.titleMetadata.process = TabProcessMetadata(foregroundProcess: "claude")

    let p = SidebarProducer(sidebarWidth: 200, cellWidth: 8, cellHeight: 16)
    let h: CGFloat = 600
    let tabBottomY = h - p.rowHeight
    // Three info lines => drawnLines = 4; compute the same title baseline as
    // the producer so the test hits the actual glyph position.
    let drawnLines: CGFloat = 4
    let edgePad: CGFloat = 4
    let yOffset = max(0, (p.rowHeight - 2 * edgePad - drawnLines * p.cellHeight) / 2)
    let titleBaselineY = tabBottomY + edgePad + yOffset + (drawnLines - 1) * p.cellHeight
    let result = p.hitTest(at: CGPoint(x: 190, y: titleBaselineY), tabs: [tab], height: h)
    XCTAssertEqual(result, .closeTab(tab.id))
  }

  func testHitTestCloseBoxReservesTitleGutterAtNarrowWidth() {
    // At narrow widths the truncated title ends very close to the close
    // slot; the hit target must stay inside the renderer's 4 pt gutter so
    // clicks on the trailing title pixels select rather than close.
    var tab = Tab(
      id: "t",
      position: 1,
      title: String(repeating: "long-title-", count: 20),
      isActive: false,
      sessionId: "s"
    )
    let p = SidebarProducer(sidebarWidth: 140, cellWidth: 8, cellHeight: 16)
    let h: CGFloat = 600
    let tabBottomY = h - p.rowHeight
    let titleBaselineY = tabBottomY + (p.rowHeight - p.cellHeight) / 2
    // titleMaxScalars = 10 => title ends at 36 + 80 = 116, gutter ends at 120.
    XCTAssertEqual(
      p.hitTest(at: CGPoint(x: 118, y: titleBaselineY), tabs: [tab], height: h),
      .selectTab(tab.id),
      "click inside the title gutter should select, not close")
    XCTAssertEqual(
      p.hitTest(at: CGPoint(x: 122, y: titleBaselineY), tabs: [tab], height: h),
      .closeTab(tab.id),
      "click past the gutter in the close slot should close")
  }

  func testHitTestRightEdgeBelowCloseSelectsTab() {
    // The close slot covers the title band and a half cell of padding below
    // it, but the bottom strip of the row is still for selecting the tab.
    let tabs = makeTabs(count: 1)
    let p = SidebarProducer(sidebarWidth: 200, cellWidth: 8, cellHeight: 16)
    let h: CGFloat = 600
    let tabBottomY = h - p.rowHeight
    let lowerBandY = tabBottomY + 8  // bottom of the row, well below the X
    let result = p.hitTest(at: CGPoint(x: 190, y: lowerBandY), tabs: tabs, height: h)
    XCTAssertEqual(result, .selectTab(tabs[0].id))
  }

  func testCloseGlyphHiddenWhenTabNotHovered() {
    let tabs = makeTabs(count: 1)
    let p = SidebarProducer(sidebarWidth: 200, cellWidth: 8, cellHeight: 16)
    let cmds = p.commands(tabs: tabs, activeTabId: tabs[0].id, height: 600)
    let texts = cmds.compactMap { cmd -> String? in
      if case .glyphRun(_, let text, _, _, _, _, _, _, _, _, _) = cmd { return text }
      return nil
    }
    XCTAssertFalse(texts.contains("✕"), "close glyph must be hidden until hover")
  }

  func testCloseGlyphShownWhenTabHovered() {
    let tabs = makeTabs(count: 1)
    let p = SidebarProducer(sidebarWidth: 200, cellWidth: 8, cellHeight: 16)
    let cmds = p.commands(
      tabs: tabs, activeTabId: tabs[0].id, height: 600,
      hoveredTabId: tabs[0].id)
    let texts = cmds.compactMap { cmd -> String? in
      if case .glyphRun(_, let text, _, _, _, _, _, _, _, _, _) = cmd { return text }
      return nil
    }
    XCTAssertTrue(texts.contains("✕"), "close glyph must appear on hover")
  }

  /// The whole point of the right-edge slot redesign: the indicator dot and
  /// the close-X anchor at the same x, so hovering swaps the glyph without
  /// shifting layout. If these drift apart, the user sees the row reflow
  /// every time the cursor enters or leaves.
  func testIndicatorAndCloseGlyphShareRightEdgeSlot() {
    // Indicators only render on background tabs, so make this tab inactive by
    // pointing `activeTabId` at a different id.
    var tab = Tab(id: "t", position: 1, title: "zsh", isActive: false, sessionId: "s")
    tab.titleMetadata.agentStatus = TabAgentStatus(indicatorColor: "#00ff00")
    let p = SidebarProducer(sidebarWidth: 200, cellWidth: 8, cellHeight: 16)

    let dotX = p.commands(tabs: [tab], activeTabId: "other", height: 600)
      .compactMap { cmd -> CGFloat? in
        if case .glyphRun(let origin, let text, _, _, _, _, _, _, _, _, _) = cmd,
          text == "●"
        {
          return origin.x
        }
        return nil
      }.first
    let xX = p.commands(
      tabs: [tab], activeTabId: "other", height: 600, hoveredTabId: tab.id
    )
    .compactMap { cmd -> CGFloat? in
      if case .glyphRun(let origin, let text, _, _, _, _, _, _, _, _, _) = cmd,
        text == "✕"
      {
        return origin.x
      }
      return nil
    }.first

    XCTAssertNotNil(dotX, "expected indicator dot")
    XCTAssertNotNil(xX, "expected close glyph on hover")
    XCTAssertEqual(dotX ?? -1, xX ?? -2, accuracy: 0.001)
  }

  /// Hover replaces the indicator instead of rendering alongside it.
  /// Otherwise close-on-hover would visually crowd the indicator and the
  /// indicator's color would compete with the close affordance.
  func testHoverHidesIndicator() {
    // Inactive tab so the agent dot is present to begin with; hover must then
    // swap it for the close glyph rather than rendering both.
    var tab = Tab(id: "t", position: 1, title: "zsh", isActive: false, sessionId: "s")
    tab.titleMetadata.agentStatus = TabAgentStatus(indicatorColor: "#00ff00")
    let p = SidebarProducer(sidebarWidth: 200, cellWidth: 8, cellHeight: 16)

    let idleTexts = p.commands(tabs: [tab], activeTabId: "other", height: 600)
      .compactMap { cmd -> String? in
        if case .glyphRun(_, let text, _, _, _, _, _, _, _, _, _) = cmd { return text }
        return nil
      }
    XCTAssertTrue(idleTexts.contains("●"), "indicator must render when not hovered")

    let cmds = p.commands(
      tabs: [tab], activeTabId: "other", height: 600, hoveredTabId: tab.id)
    let texts = cmds.compactMap { cmd -> String? in
      if case .glyphRun(_, let text, _, _, _, _, _, _, _, _, _) = cmd { return text }
      return nil
    }
    XCTAssertTrue(texts.contains("✕"), "close glyph must render on hover")
    XCTAssertFalse(
      texts.contains("●"),
      "indicator must not render alongside the close glyph — they share the slot")
  }

  func testHitTestOutsideSidebar() {
    let p = SidebarProducer(sidebarWidth: 200, cellWidth: 8, cellHeight: 16)
    let result = p.hitTest(at: CGPoint(x: 250, y: 300), tabs: [], height: 600)
    XCTAssertEqual(result, .none)
  }

  func testTopTabGeometryStaysTopAnchoredAcrossResizeHeights() {
    let tabs = makeTabs(count: 1)
    let p = SidebarProducer(sidebarWidth: 200, cellWidth: 8, cellHeight: 16)
    let topInset: CGFloat = 28
    var expectedTabTop: CGFloat?
    var expectedTitleBaselineTop: CGFloat?

    for height in [620, 634, 760, 874] as [CGFloat] {
      let cmds = p.commands(
        tabs: tabs,
        activeTabId: tabs[0].id,
        height: height,
        topInset: topInset)
      let tabRect = cmds.compactMap { cmd -> CGRect? in
        guard case .rect(let rect, _, let source, _) = cmd,
          source == .sidebar,
          rect.width == p.sidebarWidth,
          rect.height == p.rowHeight
        else { return nil }
        return rect
      }.first
      let titleRun = cmds.compactMap { cmd -> CGPoint? in
        guard case .glyphRun(let origin, let text, _, _, _, let source, _, _, _, _, _) = cmd,
          source == .sidebar,
          text == "Tab 1"
        else { return nil }
        return origin
      }.first

      XCTAssertNotNil(tabRect)
      XCTAssertNotNil(titleRun)
      guard let tabRect, let titleRun else { continue }

      let tabTop = height - (tabRect.origin.y + tabRect.height)
      let titleBaselineTop = height - titleRun.y
      if expectedTabTop == nil {
        expectedTabTop = tabTop
        expectedTitleBaselineTop = titleBaselineTop
      }
      XCTAssertEqual(tabTop, expectedTabTop ?? -1, accuracy: 0.001)
      XCTAssertEqual(titleBaselineTop, expectedTitleBaselineTop ?? -1, accuracy: 0.001)
    }

    XCTAssertEqual(expectedTabTop ?? -1, topInset)
  }

  func testHitTestEmptyAreaBelowRows() {
    let tabs = makeTabs(count: 1)
    let p = SidebarProducer(sidebarWidth: 200, cellWidth: 8, cellHeight: 16)
    // y=0 is below all rows (no tab occupies the very bottom)
    let result = p.hitTest(at: CGPoint(x: 50, y: 2), tabs: tabs, height: 600)
    XCTAssertEqual(result, .none)
  }

  // MARK: - Exit indicator tests

  func testExitedTabLabelHasStopPrefix() {
    var tab = Tab(id: "t", position: 1, title: "zsh", isActive: false, sessionId: "s")
    tab.status = .exited(code: 1)
    tab.titleMetadata.activityState = .exited
    tab.titleMetadata.exitStatus = 1
    let p = SidebarProducer(sidebarWidth: 200, cellWidth: 8, cellHeight: 16)
    let cmds = p.commands(tabs: [tab], activeTabId: nil, height: 600)
    let labelTexts = cmds.compactMap { cmd -> String? in
      if case .glyphRun(_, let text, _, _, _, _, _, _, _, _, _) = cmd { return text }
      return nil
    }
    XCTAssertTrue(
      labelTexts.contains(where: { $0 == "!" }),
      "exited nonzero tab label must contain attention marker; got \(labelTexts)")
    XCTAssertTrue(
      labelTexts.contains(where: { $0.contains("exited 1") }),
      "exited tab secondary text must contain exit status; got \(labelTexts)")
  }

  func testExitedTabUsesdimForeground() {
    var tab = Tab(id: "t", position: 1, title: "zsh", isActive: true, sessionId: "s")
    tab.status = .exited(code: 0)
    tab.titleMetadata.activityState = .exited
    tab.titleMetadata.exitStatus = 0
    let p = SidebarProducer(sidebarWidth: 200, cellWidth: 8, cellHeight: 16)
    let cmds = p.commands(tabs: [tab], activeTabId: tab.id, height: 600)
    let labelRuns = cmds.compactMap { cmd -> (String, UInt32)? in
      if case .glyphRun(_, let text, let fg, _, _, _, _, _, _, _, _) = cmd, text == "zsh" {
        return (text, fg)
      }
      return nil
    }
    XCTAssertFalse(labelRuns.isEmpty, "expected a title glyph run")
    for (_, fg) in labelRuns {
      XCTAssertEqual(
        fg, Theme.current.dim0,
        "exited active tab must use dim0 foreground, got \(String(format: "%08X", fg))")
    }
  }

  func testRunningActiveTabUsesNormalForeground() {
    let tabs = makeTabs(count: 1)
    XCTAssertEqual(tabs[0].status, .running)
    let p = SidebarProducer(sidebarWidth: 200, cellWidth: 8, cellHeight: 16)
    let cmds = p.commands(tabs: tabs, activeTabId: tabs[0].id, height: 600)
    let labelRuns = cmds.compactMap { cmd -> (String, UInt32)? in
      if case .glyphRun(_, let text, let fg, _, _, _, _, _, _, _, _) = cmd, text.contains("Tab") {
        return (text, fg)
      }
      return nil
    }
    XCTAssertFalse(labelRuns.isEmpty, "expected tab label glyph run")
    for (_, fg) in labelRuns {
      XCTAssertNotEqual(
        fg, Theme.current.dim0,
        "running active tab must not use dim0 foreground")
    }
  }

  func testLongTitleDoesNotOverlapCloseAffordanceAtNarrowWidth() {
    var tab = Tab(
      id: "t",
      position: 1,
      title: String(repeating: "long-title-", count: 20),
      isActive: true,
      sessionId: "s"
    )
    tab.titleMetadata.workspace = TabWorkspaceMetadata(
      repoName: "laban",
      worktreeName: "very-long-worktree-name",
      branch: "main",
      isDirty: true
    )
    tab.titleMetadata.process = TabProcessMetadata(foregroundProcess: "claude")

    let p = SidebarProducer(sidebarWidth: 140, cellWidth: 8, cellHeight: 16)
    let cmds = p.commands(tabs: [tab], activeTabId: tab.id, height: 600)
    let textRuns = cmds.compactMap { cmd -> (CGPoint, String)? in
      if case .glyphRun(let origin, let text, _, _, _, _, _, _, _, _, _) = cmd {
        return (origin, text)
      }
      return nil
    }

    for (origin, text) in textRuns where text != "+" && text != "x" && text != "×" {
      let right = origin.x + CGFloat(text.count) * p.cellWidth
      XCTAssertLessThanOrEqual(
        right,
        140 - 20,
        "text \(text) should reserve close-control space")
    }
  }

  func testSecondaryMetadataLineIsRenderedWhenAvailable() {
    var tab = Tab(id: "t", position: 3, title: "auth retry cleanup", isActive: true, sessionId: "s")
    tab.titleMetadata.workspace = TabWorkspaceMetadata(
      repoName: "laban",
      worktreeName: "cobra",
      branch: "main",
      isDirty: true
    )
    tab.titleMetadata.process = TabProcessMetadata(foregroundProcess: "claude")

    let p = SidebarProducer(sidebarWidth: 320, cellWidth: 8, cellHeight: 16)
    let cmds = p.commands(tabs: [tab], activeTabId: tab.id, height: 600)
    let texts = cmds.compactMap { cmd -> String? in
      if case .glyphRun(_, let text, _, _, _, _, _, _, _, _, _) = cmd { return text }
      return nil
    }

    XCTAssertTrue(texts.contains("auth retry cleanup"))
    // Each meaningful field gets its own line: folder (repo@worktree),
    // branch with dirty marker, foreground process.
    XCTAssertTrue(
      texts.contains("laban@cobra"),
      "expected workspace folder line; got \(texts)")
    XCTAssertTrue(
      texts.contains("main*"),
      "expected branch line with dirty marker; got \(texts)")
    XCTAssertTrue(
      texts.contains("claude"),
      "expected foreground process line; got \(texts)")
  }

  func testHomeCwdTitleDoesNotRenderDuplicateMetadataLine() {
    var tab = Tab(id: "t", position: 1, title: "Tab 1", isActive: true, sessionId: "s")
    tab.titleMetadata.workspace = TabWorkspaceMetadata(cwd: NSHomeDirectory())
    tab.titleMetadata.process = TabProcessMetadata(
      foregroundProcess: "bash",
      foregroundCommand: "/bin/bash",
      foregroundArguments: ["/bin/sh"]
    )

    let p = SidebarProducer(sidebarWidth: 320, cellWidth: 8, cellHeight: 16)
    let cmds = p.commands(tabs: [tab], activeTabId: tab.id, height: 600)
    let texts = cmds.compactMap { cmd -> String? in
      if case .glyphRun(_, let text, _, _, _, _, _, _, _, _, _) = cmd { return text }
      return nil
    }

    XCTAssertEqual(texts.filter { $0 == "~" }.count, 1, "got \(texts)")
  }

  func testUnseenOutputRendersAttentionMarker() {
    var tab = Tab(id: "t", position: 1, title: "zsh", isActive: false, sessionId: "s")
    tab.titleMetadata.unseenOutput = true
    tab.titleMetadata.activityState = .unseenOutput

    let p = SidebarProducer(sidebarWidth: 200, cellWidth: 8, cellHeight: 16)
    let cmds = p.commands(tabs: [tab], activeTabId: nil, height: 600)
    let texts = cmds.compactMap { cmd -> String? in
      if case .glyphRun(_, let text, _, _, _, _, _, _, _, _, _) = cmd { return text }
      return nil
    }

    XCTAssertTrue(texts.contains("*"))
  }

  func testBellAttentionRendersDotMarker() {
    var tab = Tab(id: "t", position: 1, title: "zsh", isActive: false, sessionId: "s")
    tab.titleMetadata.bellAttention = true

    let p = SidebarProducer(sidebarWidth: 200, cellWidth: 8, cellHeight: 16)
    let cmds = p.commands(tabs: [tab], activeTabId: nil, height: 600)
    let texts = cmds.compactMap { cmd -> String? in
      if case .glyphRun(_, let text, _, _, _, _, _, _, _, _, _) = cmd { return text }
      return nil
    }

    XCTAssertTrue(texts.contains("•"))
  }

  func testAgentIndicatorWinsOverBellAttention() {
    var tab = Tab(id: "t", position: 1, title: "zsh", isActive: false, sessionId: "s")
    tab.titleMetadata.bellAttention = true
    tab.titleMetadata.agentStatus = TabAgentStatus(indicatorColor: "#00ff00")

    let p = SidebarProducer(sidebarWidth: 200, cellWidth: 8, cellHeight: 16)
    let cmds = p.commands(tabs: [tab], activeTabId: nil, height: 600)
    let texts = cmds.compactMap { cmd -> String? in
      if case .glyphRun(_, let text, _, _, _, _, _, _, _, _, _) = cmd { return text }
      return nil
    }

    XCTAssertTrue(texts.contains("●"))
    XCTAssertFalse(texts.contains("•"))
  }

  // MARK: - quiet idle / focused tabs (always-on-dot removal)

  /// The headline fix: a background tab whose foreground program is merely
  /// running (OSC 133 pins `.running` for the program's whole life) must show
  /// no right-edge indicator. Previously this lit a permanent blue dot.
  func testRunningBackgroundTabHasNoIndicator() {
    var tab = Tab(id: "t", position: 1, title: "claude", isActive: false, sessionId: "s")
    tab.titleMetadata.shellPhase = .running
    let p = SidebarProducer(sidebarWidth: 200, cellWidth: 8, cellHeight: 16)
    let cmds = p.commands(tabs: [tab], activeTabId: "other", height: 600)
    let texts = cmds.compactMap { cmd -> String? in
      if case .glyphRun(_, let text, _, _, _, _, _, _, _, _, _) = cmd { return text }
      return nil
    }
    for marker in ["●", "◆", "!", "*", "•"] {
      XCTAssertFalse(
        texts.contains(marker),
        "a merely-running background tab must show no \(marker) indicator; got \(texts)")
    }
  }

  /// A failed command still earns a red dot — the failure case is the one
  /// shell-phase state worth surfacing.
  func testFailedCommandBackgroundTabShowsRedIndicator() {
    var tab = Tab(id: "t", position: 1, title: "zsh", isActive: false, sessionId: "s")
    tab.titleMetadata.shellPhase = .atPrompt
    tab.titleMetadata.lastCommandExitCode = 1
    let p = SidebarProducer(sidebarWidth: 200, cellWidth: 8, cellHeight: 16)
    let cmds = p.commands(tabs: [tab], activeTabId: "other", height: 600)
    let dot = cmds.compactMap { cmd -> UInt32? in
      if case .glyphRun(_, let text, let fg, _, _, _, _, _, _, _, _) = cmd, text == "●" {
        return fg
      }
      return nil
    }.first
    XCTAssertEqual(dot, Theme.current.red, "failed command must show a red dot")
  }

  /// The focused/active tab is quiet even when it carries attention state —
  /// you are already looking at it.
  func testActiveTabSuppressesIndicator() {
    var tab = Tab(id: "t", position: 1, title: "zsh", isActive: true, sessionId: "s")
    tab.titleMetadata.bellAttention = true
    tab.titleMetadata.lastCommandExitCode = 1
    tab.titleMetadata.unseenOutput = true
    let p = SidebarProducer(sidebarWidth: 200, cellWidth: 8, cellHeight: 16)
    let cmds = p.commands(tabs: [tab], activeTabId: tab.id, height: 600)
    let texts = cmds.compactMap { cmd -> String? in
      if case .glyphRun(_, let text, _, _, _, _, _, _, _, _, _) = cmd { return text }
      return nil
    }
    for marker in ["●", "◆", "!", "*", "•"] {
      XCTAssertFalse(
        texts.contains(marker),
        "the active tab must show no \(marker) indicator; got \(texts)")
    }
  }

  // MARK: - attention tiers (needs-you vs done vs passive)

  func testNeedsActionRendersAttentionDiamondAndRowTint() {
    var tab = Tab(id: "t", position: 1, title: "claude", isActive: false, sessionId: "s")
    tab.titleMetadata.activityState = .waiting
    let p = SidebarProducer(sidebarWidth: 200, cellWidth: 8, cellHeight: 16)
    let cmds = p.commands(tabs: [tab], activeTabId: "other", height: 600)

    // A ◆ marker whose RGB is the theme's attention accent (yellow — red is
    // reserved for failures). Compare RGB only — M3 modulates the alpha byte
    // for the breathing pulse.
    let marker = cmds.compactMap { cmd -> UInt32? in
      if case .glyphRun(_, let text, let fg, _, _, _, _, _, _, _, _) = cmd, text == "◆" {
        return fg
      }
      return nil
    }.first
    XCTAssertNotNil(marker, "needsAction must render a ◆ marker")
    XCTAssertEqual(
      (marker ?? 0) | 0xFF, Theme.current.attention | 0xFF,
      "marker RGB must be the theme's attention accent")
    XCTAssertNotEqual(
      Theme.current.attention | 0xFF, Theme.current.red | 0xFF,
      "attention accent must stay distinct from the failure red")

    // The full-width row rect is washed toward the attention accent — neither
    // the plain inactive bg nor the active-tab bg.
    let rowColors = cmds.compactMap { cmd -> UInt32? in
      if case .rect(let r, let c, _, _) = cmd, r.width == p.sidebarWidth, r.height == p.rowHeight {
        return c
      }
      return nil
    }
    XCTAssertTrue(
      rowColors.contains { $0 != Theme.current.bg1 && $0 != Theme.current.bg2 },
      "needsAction row must be tinted; got \(rowColors.map { String(format: "%08X", $0) })")
  }

  func testDoneRendersAccentDiamondWithoutTint() {
    var tab = Tab(id: "t", position: 1, title: "build", isActive: false, sessionId: "s")
    tab.titleMetadata.notification = TabNotification(text: "build complete", urgent: false)
    let p = SidebarProducer(sidebarWidth: 200, cellWidth: 8, cellHeight: 16)
    let cmds = p.commands(tabs: [tab], activeTabId: "other", height: 600)

    let marker = cmds.compactMap { cmd -> UInt32? in
      if case .glyphRun(_, let text, let fg, _, _, _, _, _, _, _, _) = cmd, text == "◆" {
        return fg
      }
      return nil
    }.first
    XCTAssertEqual(marker, Theme.current.cursor, "done marker uses the accent colour")

    let rowTinted = cmds.contains { cmd in
      if case .rect(let r, let c, _, _) = cmd, r.width == p.sidebarWidth, r.height == p.rowHeight {
        return c != Theme.current.bg1
      }
      return false
    }
    XCTAssertFalse(rowTinted, "done tab must not tint the row")
  }

  /// Regression: a tab whose stack mixes a notification/status line with
  /// info lines was sized from `resolved.infoLines.count`, which excludes
  /// those extra lines. The row then rendered more lines than it was sized
  /// for, so the bottom line dropped below the row edge and crowded the next
  /// tab (the "ready ×2" screenshot). Every rendered line must stay within its
  /// own row.
  func testNotificationStackDoesNotSpillIntoNextTab() {
    var tab = Tab(id: "t", position: 1, title: "gpu-work", isActive: false, sessionId: "s")
    tab.titleMetadata.notification = TabNotification(text: "done", urgent: false, count: 2)
    tab.titleMetadata.agentStatus = TabAgentStatus(statusText: "thinking")
    tab.titleMetadata.workspace = TabWorkspaceMetadata(repoName: "sixten-runtime")

    let p = SidebarProducer(sidebarWidth: 200, cellWidth: 8, cellHeight: 16)
    let height: CGFloat = 600
    let cmds = p.commands(tabs: [tab], activeTabId: "other", height: height)

    // The single top tab occupies [tabY, tabY + rowHeight] with topInset 0.
    let tabY = height - p.rowHeight
    let origins = cmds.compactMap { cmd -> CGPoint? in
      if case .glyphRun(let origin, _, _, _, _, _, _, _, _, _, _) = cmd { return origin }
      return nil
    }
    XCTAssertFalse(origins.isEmpty)
    for o in origins {
      XCTAssertGreaterThanOrEqual(
        o.y, tabY,
        "tab text must stay within its row, not spill below into the next tab")
    }
  }

  /// An explicit OSC 21337 agent colour beats passive activity for the slot,
  /// but a real needsAction state beats the agent colour.
  func testNeedsActionBeatsExplicitAgentDot() {
    var tab = Tab(id: "t", position: 1, title: "codex", isActive: false, sessionId: "s")
    tab.titleMetadata.agentStatus = TabAgentStatus(indicatorColor: "#00ff00")
    tab.titleMetadata.agent.awaitingInput = true
    let p = SidebarProducer(sidebarWidth: 200, cellWidth: 8, cellHeight: 16)
    let texts = p.commands(tabs: [tab], activeTabId: "other", height: 600)
      .compactMap { cmd -> String? in
        if case .glyphRun(_, let text, _, _, _, _, _, _, _, _, _) = cmd { return text }
        return nil
      }
    XCTAssertTrue(texts.contains("◆"), "needs-action ◆ wins the slot")
    XCTAssertFalse(texts.contains("●"), "the agent dot is superseded by needs-action")
  }

  /// Passive activity (unseen output) is muted, not red — it informs without
  /// shouting.
  func testPassiveMarkerIsMuted() {
    var tab = Tab(id: "t", position: 1, title: "zsh", isActive: false, sessionId: "s")
    tab.titleMetadata.unseenOutput = true
    let p = SidebarProducer(sidebarWidth: 200, cellWidth: 8, cellHeight: 16)
    let marker = p.commands(tabs: [tab], activeTabId: "other", height: 600)
      .compactMap { cmd -> UInt32? in
        if case .glyphRun(_, let text, let fg, _, _, _, _, _, _, _, _) = cmd, text == "*" {
          return fg
        }
        return nil
      }.first
    XCTAssertEqual(marker, Theme.current.dim0, "passive marker is dim, not red")
  }

  /// The needsAction marker follows the announce-once timeline: fading in
  /// (with a halo bloom) through the entrance, resting static at full
  /// opacity, dipping to the ping floor on each re-ping — and rendering the
  /// static rest form when no entry time is recorded.
  func testNeedsActionMarkerFollowsAnnounceOnceTimeline() {
    var tab = Tab(id: "t", position: 1, title: "claude", isActive: false, sessionId: "s")
    tab.titleMetadata.activityState = .waiting
    let p = SidebarProducer(sidebarWidth: 200, cellWidth: 8, cellHeight: 16)
    let out = p.output(tabs: [tab], activeTabId: "other", height: 600)
    XCTAssertEqual(out.pulseMarkers.count, 1)
    XCTAssertEqual(out.pulseMarkers.first?.tabId, "t")

    let entry = Date(timeIntervalSinceReferenceDate: 0)
    func retint(at t: TimeInterval, entryTimes: [Tab.ID: Date] = ["t": entry]) -> [FrameCommand] {
      SidebarProducer.retintPulseMarkers(
        out, at: Date(timeIntervalSinceReferenceDate: t),
        entryTimes: entryTimes, cellWidth: 8, cellHeight: 16, maxX: 200)
    }
    func markerAlpha(_ cmds: [FrameCommand]) -> UInt32? {
      cmds.compactMap { cmd -> UInt32? in
        if case .glyphRun(_, let text, let fg, _, _, _, _, _, _, _, _) = cmd, text == "◆" {
          return fg & 0xFF
        }
        return nil
      }.first
    }

    let mid = retint(at: AttentionPulse.entranceDuration / 2)
    let midAlpha = markerAlpha(mid) ?? 0
    XCTAssertGreaterThan(midAlpha, 0)
    XCTAssertLessThan(midAlpha, 0xFF, "mid-entrance the marker is still fading in")
    XCTAssertGreaterThan(mid.count, out.commands.count, "the entrance appends a halo bloom rect")

    let rest = retint(at: 10)
    XCTAssertEqual(markerAlpha(rest), 0xFF, "at rest the marker is static at full opacity")
    XCTAssertEqual(rest.count, out.commands.count, "no halo outside the entrance")

    let ping = retint(
      at: AttentionPulse.entranceDuration + AttentionPulse.pingPeriod
        + AttentionPulse.pingDuration / 2)
    XCTAssertEqual(
      markerAlpha(ping), UInt32((AttentionPulse.pingFloor * 255).rounded()),
      "the re-ping dips to its floor at the bump midpoint")

    let unknown = retint(at: 0.1, entryTimes: [:])
    XCTAssertEqual(markerAlpha(unknown), 0xFF, "no recorded entry renders the static rest form")
  }

  // MARK: - scroll overflow

  func testMaxScrollOffsetOnlyAppearsWhenRowsOverflow() {
    let p = SidebarProducer(sidebarWidth: 200, cellWidth: 8, cellHeight: 16)
    XCTAssertEqual(p.maxScrollOffset(tabCount: 2, height: 600), 0)

    let overflowingHeight = p.rowHeight * 3
    XCTAssertEqual(
      p.maxScrollOffset(tabCount: 5, height: overflowingHeight),
      p.rowHeight * 2,
      accuracy: 0.001)
  }

  func testScrollOffsetRevealsOverflowRowsWithoutDrawingHiddenRows() {
    let tabs = makeTabs(count: 12)
    let p = SidebarProducer(sidebarWidth: 200, cellWidth: 8, cellHeight: 16)
    let height = p.rowHeight * 3
    let offset = p.maxScrollOffset(tabCount: tabs.count, height: height)
    let texts = p.commands(
      tabs: tabs,
      activeTabId: tabs[11].id,
      height: height,
      scrollOffset: offset
    ).compactMap { cmd -> String? in
      if case .glyphRun(_, let text, _, _, _, _, _, _, _, _, _) = cmd { return text }
      return nil
    }

    XCTAssertTrue(texts.contains("Tab 12"), "bottom overflow row should be visible")
    XCTAssertFalse(texts.contains("Tab 1"), "top row should be clipped away after scrolling")
  }

  func testHitTestUsesScrollOffset() {
    let tabs = makeTabs(count: 5)
    let p = SidebarProducer(sidebarWidth: 200, cellWidth: 8, cellHeight: 16)
    let height = p.rowHeight * 2
    let offset = p.maxScrollOffset(tabCount: tabs.count, height: height)

    let result = p.hitTest(
      at: CGPoint(x: 50, y: p.rowHeight / 2),
      tabs: tabs,
      height: height,
      scrollOffset: offset)
    XCTAssertEqual(result, .selectTab(tabs[4].id))
  }

  func testDropSlotUsesScrollOffset() {
    let tabs = makeTabs(count: 5)
    let p = SidebarProducer(sidebarWidth: 200, cellWidth: 8, cellHeight: 16)
    let height = p.rowHeight * 2
    let offset = p.maxScrollOffset(tabCount: tabs.count, height: height)

    XCTAssertEqual(
      p.dropSlot(
        at: CGPoint(x: 50, y: 1),
        tabs: tabs,
        height: height,
        scrollOffset: offset),
      5)
  }

  // MARK: - drag-reorder

  func testDropSlotAboveFirstRowReturnsZero() {
    let tabs = makeTabs(count: 3)
    let p = SidebarProducer(sidebarWidth: 200, cellWidth: 8, cellHeight: 16)
    let h: CGFloat = 600
    let slot = p.dropSlot(at: CGPoint(x: 50, y: h - 1), tabs: tabs, height: h)
    XCTAssertEqual(slot, 0)
  }

  func testDropSlotMidpointBoundariesAreInclusiveTowardEarlierRow() {
    let tabs = makeTabs(count: 3)
    let p = SidebarProducer(sidebarWidth: 200, cellWidth: 8, cellHeight: 16)
    let h: CGFloat = 600

    // Top half of row 0 -> slot 0 (insert before row 0).
    let topHalfY = h - 1
    XCTAssertEqual(p.dropSlot(at: CGPoint(x: 50, y: topHalfY), tabs: tabs, height: h), 0)

    // Bottom half of row 0 -> slot 1 (insert after row 0 / before row 1).
    let row0Bottom = h - p.rowHeight
    let bottomHalfY = row0Bottom + 1
    XCTAssertEqual(p.dropSlot(at: CGPoint(x: 50, y: bottomHalfY), tabs: tabs, height: h), 1)
  }

  func testDropSlotBelowLastRowReturnsTabCount() {
    let tabs = makeTabs(count: 3)
    let p = SidebarProducer(sidebarWidth: 200, cellWidth: 8, cellHeight: 16)
    let h: CGFloat = 600
    let slot = p.dropSlot(at: CGPoint(x: 50, y: 0), tabs: tabs, height: h)
    XCTAssertEqual(slot, 3)
  }

  func testDropSlotEmptyTabsReturnsNil() {
    let p = SidebarProducer(sidebarWidth: 200, cellWidth: 8, cellHeight: 16)
    XCTAssertNil(p.dropSlot(at: CGPoint(x: 50, y: 300), tabs: [], height: 600))
  }

  func testDropSlotRespectsTopInset() {
    let tabs = makeTabs(count: 2)
    let p = SidebarProducer(sidebarWidth: 200, cellWidth: 8, cellHeight: 16)
    let h: CGFloat = 600
    let inset: CGFloat = 28

    // Inside the inset strip → still slot 0 (above the first row).
    XCTAssertEqual(
      p.dropSlot(
        at: CGPoint(x: 50, y: h - inset / 2), tabs: tabs, height: h, topInset: inset),
      0)
  }

  func testDragIndicatorDrawsAccentBarAtSlotBoundary() {
    let tabs = makeTabs(count: 3)
    let p = SidebarProducer(sidebarWidth: 200, cellWidth: 8, cellHeight: 16)
    let h: CGFloat = 600
    let cmds = p.commands(
      tabs: tabs, activeTabId: tabs[0].id, height: h,
      dragIndicator: SidebarProducer.DragIndicator(slot: 2, draggingTabId: tabs[0].id))
    let accent = cmds.compactMap { cmd -> CGRect? in
      if case .rect(let r, let c, _, _) = cmd, c == Theme.current.blue, r.height < 4 {
        return r
      }
      return nil
    }
    XCTAssertEqual(accent.count, 1, "exactly one drop-target accent bar")
    XCTAssertEqual(accent.first!.width, p.sidebarWidth, accuracy: 0.5)
  }

  func testDragIndicatorSkipsAccentWhenDropWouldNotMove() {
    let tabs = makeTabs(count: 3)
    let p = SidebarProducer(sidebarWidth: 200, cellWidth: 8, cellHeight: 16)
    let h: CGFloat = 600
    // Dragging tab at index 1 — slot 1 and slot 2 would both re-insert
    // it in place. The accent should be suppressed for both.
    for slot in [1, 2] {
      let cmds = p.commands(
        tabs: tabs, activeTabId: tabs[0].id, height: h,
        dragIndicator: SidebarProducer.DragIndicator(slot: slot, draggingTabId: tabs[1].id))
      let accent = cmds.contains { cmd in
        if case .rect(let r, let c, _, _) = cmd, c == Theme.current.blue, r.height < 4 {
          return true
        }
        return false
      }
      XCTAssertFalse(accent, "slot \(slot) is a no-op move; no accent bar")
    }
  }

  func testDragIndicatorDimsDraggingRow() {
    let tabs = makeTabs(count: 2)
    let p = SidebarProducer(sidebarWidth: 200, cellWidth: 8, cellHeight: 16)
    let h: CGFloat = 600
    let cmds = p.commands(
      tabs: tabs, activeTabId: tabs[0].id, height: h,
      dragIndicator: SidebarProducer.DragIndicator(slot: 2, draggingTabId: tabs[0].id))
    let overlay = cmds.contains { cmd in
      if case .rect(let r, let c, _, _) = cmd,
        (c & 0xFF) > 0, (c & 0xFF) < 0xFF,
        r.width == p.sidebarWidth, r.height == p.rowHeight
      {
        return true
      }
      return false
    }
    XCTAssertTrue(overlay, "the dragging row gets a translucent dim overlay")
  }
}
