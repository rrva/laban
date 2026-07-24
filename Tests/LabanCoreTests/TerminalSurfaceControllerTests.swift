import CoreGraphics
import Foundation
import LabanRenderer
import LabanTerminalCore
import XCTest

@testable import LabanCore

final class TerminalSurfaceControllerTests: XCTestCase {
  private final class RecordingSurfaceCaptureSink: TerminalSurfaceCaptureSink {
    var events: [CaptureTimelineEvent] = []
    var frameCommands: [[FrameCommand]] = []

    func nextSequence() -> Int { events.count + 1 }

    func record(_ event: CaptureTimelineEvent) {
      events.append(event)
    }

    func recordBytes(
      direction: CaptureByteDirection,
      sessionId: Session.ID?,
      frame: Int,
      bytes: UnsafeRawBufferPointer,
      preview: String?
    ) -> CaptureByteRef? {
      nil
    }

    func recordTerminalSnapshot(
      frame: Int,
      tabId: String?,
      sessionId: String?,
      snapshot: UnsafePointer<LabanSnapshot>
    ) -> String? {
      nil
    }

    func recordFrameCommands(
      frame: Int,
      commands: [FrameCommand],
      surfaceWidth: Int,
      surfaceHeight: Int,
      scale: Double,
      backend: String
    ) -> CaptureFrameRef? {
      frameCommands.append(commands)
      return nil
    }
  }

  private func commandKey(_ command: FrameCommand) -> String {
    func rectKey(_ rect: CGRect) -> String {
      String(
        format: "%.4f,%.4f,%.4f,%.4f", rect.origin.x, rect.origin.y, rect.width, rect.height)
    }
    func pointKey(_ point: CGPoint) -> String {
      String(format: "%.4f,%.4f", point.x, point.y)
    }
    switch command {
    case .rect(let rect, let color, let source, let compositing):
      return "rect|\(rectKey(rect))|\(color)|\(source.rawValue)|\(compositing.rawValue)"
    case .glyphRun(
      let origin, let text, let foreground, let background, let attributes, let source,
      let underlineStyle, let underlineColor, let hyperlink, _, _, _, _):
      let scalars = text.unicodeScalars.map { String($0.value, radix: 16) }.joined(separator: ".")
      return
        "glyph|\(pointKey(origin))|chars=\(text.count)|scalars=\(scalars)|fg=\(foreground)"
        + "|bg=\(background)|attrs=\(attributes.rawValue)|src=\(source.rawValue)"
        + "|us=\(underlineStyle.rawValue)|uc=\(underlineColor.map(String.init) ?? "nil")"
        + "|link=\(hyperlink ?? "nil")"
    case .cursor(let rect, let color):
      return "cursor|\(rectKey(rect))|\(color)"
    case .selection(let rect, let color):
      return "selection|\(rectKey(rect))|\(color)"
    case .findMatch(let rect, let color):
      return "findMatch|\(rectKey(rect))|\(color)"
    case .findSelected(let rect, let color):
      return "findSelected|\(rectKey(rect))|\(color)"
    case .clip(let rect):
      return "clip|\(rectKey(rect))"
    case .texturedQuad(let rect, let resourceId, let source):
      return "texturedQuad|\(rectKey(rect))|\(resourceId)|\(source.rawValue)"
    case .waveRegion:
      return "waveRegion"
    }
  }

  private func commandKeys(_ commands: [FrameCommand]) -> [String] {
    commands.map(commandKey)
  }

  func testBuildsSidebarAndTerminalFrameCommands() throws {
    var size = LabanTerminalSize()
    size.rows = 4
    size.cols = 20
    let model = try AppModel(initialSize: size)
    guard let tab = model.activeTab,
      let session = model.session(forTab: tab.id)
    else {
      XCTFail("missing active fixture session")
      return
    }

    _ = session.write(Array("hello".utf8))
    _ = session.poll()

    let controller = TerminalSurfaceController(
      model: model,
      cellWidth: 8,
      cellHeight: 16,
      sidebarWidth: 200)
    let frame = controller.makeFrame(
      TerminalSurfaceFrameRequest(
        frame: 1,
        viewportWidth: 360,
        viewportHeight: 64,
        requireActiveSnapshot: true,
        surfaceWidth: 360,
        surfaceHeight: 64,
        surfaceScale: 1))

    guard let frame else {
      XCTFail("expected a frame from the active snapshot")
      return
    }

    XCTAssertEqual(frame.tabId, tab.id)
    XCTAssertEqual(frame.sessionId, session.id)
    XCTAssertEqual(frame.rows, 4)
    XCTAssertEqual(frame.cols, 20)
    let hasSidebarRect = frame.commands.contains { command in
      if case .rect(_, _, let source, _) = command { return source == .sidebar }
      return false
    }
    XCTAssertTrue(hasSidebarRect)

    let terminalText = frame.commands.compactMap { command -> String? in
      if case .glyphRun(_, let text, _, _, _, let source, _, _, _, _, _, _, _) = command,
        source == .terminal
      {
        return text
      }
      return nil
    }.joined()
    XCTAssertTrue(terminalText.contains("hello"), "got terminal text \(terminalText)")
  }

  /// Regression test for execplans/active/sidebar-hover-preview.md's opacity
  /// bug: the preview panel's commands must come AFTER the terminal pane's
  /// own background/glyph commands in the frame's command list, or the
  /// terminal grid's every-frame repaint (painter's-algorithm order, no
  /// depth test) draws over the panel and it looks like terminal content is
  /// bleeding through it.
  func testHoverPreviewCommandsAppearAfterTerminalCommands() throws {
    var size = LabanTerminalSize()
    size.rows = 4
    size.cols = 20
    let model = try AppModel(initialSize: size)
    let activeTab = try XCTUnwrap(model.activeTab)
    _ = try model.createTab()
    let hoveredTab = try XCTUnwrap(model.activeTab)
    model.selectTab(activeTab.id)

    let activeSession = try XCTUnwrap(model.session(forTab: activeTab.id))
    _ = activeSession.write(Array("hello".utf8))
    _ = activeSession.poll()
    let hoveredSession = try XCTUnwrap(model.session(forTab: hoveredTab.id))
    _ = hoveredSession.write(Array("background output".utf8))
    _ = hoveredSession.poll()

    let controller = TerminalSurfaceController(
      model: model,
      cellWidth: 8,
      cellHeight: 16,
      sidebarWidth: 200,
      previewCellWidth: 4,
      previewCellHeight: 8)
    let frame = controller.makeFrame(
      TerminalSurfaceFrameRequest(
        frame: 1,
        viewportWidth: 800,
        viewportHeight: 600,
        hoveredSidebarTabId: hoveredTab.id,
        includeTerminalAreaBackground: true,
        requireActiveSnapshot: true,
        surfaceWidth: 800,
        surfaceHeight: 600,
        surfaceScale: 1,
        effectiveRendererIsSlug: true,
        hoverPreviewEnabled: true))

    guard let frame else {
      XCTFail("expected a frame from the active snapshot")
      return
    }

    let hasPreviewCommand = frame.commands.contains { command in
      switch command {
      case .rect(_, _, let source, _): return source == .sidebarPreview
      case .glyphRun(_, _, _, _, _, let source, _, _, _, _, _, _, _):
        return source == .sidebarPreview
      default: return false
      }
    }
    XCTAssertTrue(hasPreviewCommand, "expected at least one .sidebarPreview command")

    let lastTerminalIndex = frame.commands.lastIndex { command in
      switch command {
      case .rect(_, _, let source, _): return source == .terminal
      case .glyphRun(_, _, _, _, _, let source, _, _, _, _, _, _, _): return source == .terminal
      default: return false
      }
    }
    let firstPreviewIndex = frame.commands.firstIndex { command in
      switch command {
      case .rect(_, _, let source, _): return source == .sidebarPreview
      case .glyphRun(_, _, _, _, _, let source, _, _, _, _, _, _, _):
        return source == .sidebarPreview
      default: return false
      }
    }
    let lastTerminal = try XCTUnwrap(lastTerminalIndex)
    let firstPreview = try XCTUnwrap(firstPreviewIndex)
    XCTAssertGreaterThan(
      firstPreview, lastTerminal,
      "the preview panel must be drawn after the terminal pane's own commands so it paints on top")
  }

  /// Regression test for the "lacks color" gap: the preview must carry the
  /// hovered tab's REAL per-cell foreground color (resolved from its live
  /// snapshot via `FrameProducer`), not a single flat theme color — this is
  /// what distinguishes it from the earlier plain-`scrollbackBlock().lines()`
  /// implementation, which had no color information to preserve at all.
  func testHoverPreviewContentPreservesTerminalForegroundColor() throws {
    var size = LabanTerminalSize()
    size.rows = 4
    size.cols = 20
    let model = try AppModel(initialSize: size)
    let activeTab = try XCTUnwrap(model.activeTab)
    _ = try model.createTab()
    let hoveredTab = try XCTUnwrap(model.activeTab)
    model.selectTab(activeTab.id)

    let hoveredSession = try XCTUnwrap(model.session(forTab: hoveredTab.id))
    // 24-bit truecolor red, distinct from any default theme foreground.
    _ = hoveredSession.write(Array("\u{1B}[38;2;255;0;0mRED\u{1B}[0m".utf8))
    _ = hoveredSession.poll()

    let controller = TerminalSurfaceController(
      model: model,
      cellWidth: 8,
      cellHeight: 16,
      sidebarWidth: 200,
      previewCellWidth: 4,
      previewCellHeight: 8)
    let frame = controller.makeFrame(
      TerminalSurfaceFrameRequest(
        frame: 1,
        viewportWidth: 800,
        viewportHeight: 600,
        hoveredSidebarTabId: hoveredTab.id,
        requireActiveSnapshot: false,
        surfaceWidth: 800,
        surfaceHeight: 600,
        surfaceScale: 1,
        effectiveRendererIsSlug: true,
        hoverPreviewEnabled: true))

    let previewForegrounds = try XCTUnwrap(frame).commands.compactMap { command -> UInt32? in
      if case .glyphRun(_, _, let foreground, _, _, .sidebarPreview, _, _, _, _, _, _, _) = command
      {
        return foreground
      }
      return nil
    }
    XCTAssertTrue(
      previewForegrounds.contains { rgba in
        let r = (rgba >> 24) & 0xFF
        let g = (rgba >> 16) & 0xFF
        let b = (rgba >> 8) & 0xFF
        return r > 200 && g < 50 && b < 50
      },
      "expected a red (255,0,0) preview glyph run matching the hovered tab's real ANSI "
        + "foreground color; got \(previewForegrounds.map { String($0, radix: 16) })")
  }

  func testSidebarCommandsMemoizesAndInvalidates() throws {
    var size = LabanTerminalSize()
    size.rows = 4
    size.cols = 20
    let model = try AppModel(initialSize: size)
    let controller = TerminalSurfaceController(
      model: model,
      cellWidth: 8,
      cellHeight: 16,
      sidebarWidth: 200)
    let tabId = model.tabs[0].id

    func sidebarTexts(_ cmds: [FrameCommand]) -> [String] {
      cmds.compactMap { cmd in
        if case .glyphRun(_, let text, _, _, _, let source, _, _, _, _, _, _, _) = cmd,
          source == .sidebar
        {
          return text
        }
        return nil
      }
    }

    // First call builds; an identical call — even with a different `now` — is a
    // memo hit, because the (non-pulsing) sidebar does not depend on `now`.
    let first = controller.sidebarCommands(
      activeTabId: tabId, viewportHeight: 200, now: Date(timeIntervalSince1970: 1))
    let buildsAfterFirst = controller.sidebarRebuildCountForTesting
    let second = controller.sidebarCommands(
      activeTabId: tabId, viewportHeight: 200, now: Date(timeIntervalSince1970: 999))
    XCTAssertEqual(
      controller.sidebarRebuildCountForTesting, buildsAfterFirst,
      "identical inputs differing only in now must hit the memo")
    XCTAssertEqual(first.count, second.count)

    // The memoized commands match a fresh, uncached producer build.
    let fresh = SidebarProducer(
      sidebarWidth: 200,
      cellWidth: controller.sidebarCellWidth,
      cellHeight: controller.sidebarCellHeight
    ).commands(tabs: model.tabs, activeTabId: tabId, height: 200)
    XCTAssertEqual(sidebarTexts(second), sidebarTexts(fresh))

    // Each changed input invalidates the memo.
    var expected = buildsAfterFirst
    _ = controller.sidebarCommands(activeTabId: tabId, viewportHeight: 240)
    expected += 1
    XCTAssertEqual(
      controller.sidebarRebuildCountForTesting, expected, "viewport change must rebuild")

    _ = controller.sidebarCommands(activeTabId: tabId, viewportHeight: 240, hoveredTabId: tabId)
    expected += 1
    XCTAssertEqual(
      controller.sidebarRebuildCountForTesting, expected, "hover change must rebuild")

    try model.updateTerminalTitle("renamed-session", forTab: tabId)
    _ = controller.sidebarCommands(activeTabId: tabId, viewportHeight: 240, hoveredTabId: tabId)
    expected += 1
    XCTAssertEqual(
      controller.sidebarRebuildCountForTesting, expected, "metadata change must rebuild")
  }

  func testSidebarMemoSurvivesOutputOnlyActivityChurn() throws {
    var size = LabanTerminalSize()
    size.rows = 4
    size.cols = 20
    let model = try AppModel(initialSize: size)
    let controller = TerminalSurfaceController(
      model: model,
      cellWidth: 8,
      cellHeight: 16,
      sidebarWidth: 200)
    let tabId = model.tabs[0].id

    _ = controller.sidebarCommands(activeTabId: tabId, viewportHeight: 200)
    let baseline = controller.sidebarRebuildCountForTesting

    // An output tick bumps only the per-tab activity timestamps, which live on
    // Tab (not TabTitleMetadata) and are never drawn in the sidebar. The memo
    // must survive it — this is the per-output-tick rebuild the profiler flagged.
    try model.updateTitleMetadata(forTab: tabId, lastOutputAt: Date(timeIntervalSince1970: 500))
    try model.updateTitleMetadata(forTab: tabId, lastActivityAt: Date(timeIntervalSince1970: 600))
    _ = controller.sidebarCommands(activeTabId: tabId, viewportHeight: 200)
    XCTAssertEqual(
      controller.sidebarRebuildCountForTesting, baseline,
      "output-only activity-timestamp churn must not invalidate the sidebar memo")

    // A genuinely sidebar-visible change still rebuilds.
    try model.updateTerminalTitle("renamed", forTab: tabId)
    _ = controller.sidebarCommands(activeTabId: tabId, viewportHeight: 200)
    XCTAssertEqual(
      controller.sidebarRebuildCountForTesting, baseline + 1,
      "a sidebar-visible metadata change must still rebuild")
  }

  /// The needsAction pulse must animate WITHOUT rebuilding the sidebar:
  /// re-resolving every tab title at the display rate just to breathe one
  /// marker is what saturated the main thread (and queued keystrokes for
  /// hundreds of ms) whenever an agent tab was pulsing under streaming load.
  /// The memoized commands are re-tinted per frame at the recorded marker
  /// indices instead.
  func testPulsingAttentionMarkerAnimatesWithoutRebuildingSidebar() throws {
    var size = LabanTerminalSize()
    size.rows = 4
    size.cols = 20
    let model = try AppModel(initialSize: size)
    let controller = TerminalSurfaceController(
      model: model,
      cellWidth: 8,
      cellHeight: 16,
      sidebarWidth: 200)
    let tabId = model.tabs[0].id
    // A waiting tab that is NOT the active tab classifies as needsAction.
    try model.updateTitleMetadata(forTab: tabId, activityState: .waiting)

    func markerAlpha(_ cmds: [FrameCommand]) -> UInt32? {
      cmds.compactMap { cmd -> UInt32? in
        if case .glyphRun(_, let text, let fg, _, _, _, _, _, _, _, _, _, _) = cmd, text == "◆" {
          return fg & 0xFF
        }
        return nil
      }.first
    }

    // First call records the tab's needsAction entry time → announce begins.
    let entering = controller.sidebarCommands(
      activeTabId: nil, viewportHeight: 200,
      now: Date(timeIntervalSinceReferenceDate: 0))
    let builds = controller.sidebarRebuildCountForTesting
    let midEntrance = controller.sidebarCommands(
      activeTabId: nil, viewportHeight: 200,
      now: Date(timeIntervalSinceReferenceDate: AttentionPulse.entranceDuration / 2))
    let resting = controller.sidebarCommands(
      activeTabId: nil, viewportHeight: 200,
      now: Date(timeIntervalSinceReferenceDate: 10))

    XCTAssertEqual(
      controller.sidebarRebuildCountForTesting, builds,
      "the announce animation must be served from the memo, not rebuilt per frame")
    let enteringAlpha = try XCTUnwrap(markerAlpha(entering), "needsAction must render a marker")
    XCTAssertEqual(enteringAlpha, 0, "the marker fades in from invisible at entry")
    let midAlpha = try XCTUnwrap(markerAlpha(midEntrance))
    XCTAssertGreaterThan(midAlpha, 0)
    XCTAssertLessThan(midAlpha, 0xFF, "mid-entrance the marker is still fading in")
    XCTAssertGreaterThan(
      midEntrance.count, resting.count, "the entrance appends a halo bloom rect")
    XCTAssertEqual(
      markerAlpha(resting), 0xFF, "after the announce the marker rests at full opacity")

    // Reduce Motion serves the frozen full-opacity form, also from the memo.
    let steady = controller.sidebarCommands(
      activeTabId: nil, viewportHeight: 200,
      now: Date(timeIntervalSinceReferenceDate: 0), reduceMotion: true)
    XCTAssertEqual(markerAlpha(steady), 0xFF)
  }

  func testCellPayloadModeSkipsTerminalCommandsWhenCompatible() throws {
    var size = LabanTerminalSize()
    size.rows = 4
    size.cols = 20
    let model = try AppModel(initialSize: size)
    let tab = try XCTUnwrap(model.activeTab)
    let session = try XCTUnwrap(model.session(forTab: tab.id))

    _ = session.write(Array("hello".utf8))
    _ = session.poll()

    let controller = TerminalSurfaceController(
      model: model,
      cellWidth: 8,
      cellHeight: 16,
      sidebarWidth: 200)
    let frame = try XCTUnwrap(
      controller.makeFrame(
        TerminalSurfaceFrameRequest(
          frame: 1,
          viewportWidth: 360,
          viewportHeight: 64,
          requireActiveSnapshot: true,
          surfaceWidth: 360,
          surfaceHeight: 64,
          surfaceScale: 1,
          contentMode: .cellPayloadPreferred)))

    XCTAssertEqual(frame.tabId, tab.id)
    let payload = try XCTUnwrap(frame.cellPayload)
    XCTAssertNil(payload.fallbackReason)
    XCTAssertTrue(
      payload.glyphs.contains { $0.scalarValue == Character("h").unicodeScalars.first?.value })
    let terminalGlyphCommands = frame.commands.filter { command in
      if case .glyphRun(_, _, _, _, _, let source, _, _, _, _, _, _, _) = command {
        return source == .terminal
      }
      return false
    }
    XCTAssertTrue(terminalGlyphCommands.isEmpty)
  }

  func testBottomFollowOutputForcesFullDamageWhenViewportOffsetChanges() throws {
    var size = LabanTerminalSize()
    size.rows = 4
    size.cols = 28
    let model = try AppModel(initialSize: size)
    let tab = try XCTUnwrap(model.activeTab)
    let session = try XCTUnwrap(model.session(forTab: tab.id))
    let controller = TerminalSurfaceController(
      model: model,
      cellWidth: 8,
      cellHeight: 16,
      sidebarWidth: 0)

    func makeFrame(_ frame: Int, forceFull: Bool) throws -> TerminalSurfaceFrame {
      try XCTUnwrap(
        controller.makeFrame(
          TerminalSurfaceFrameRequest(
            frame: frame,
            viewportWidth: 224,
            viewportHeight: 64,
            requireActiveSnapshot: true,
            forceFullDamage: forceFull,
            surfaceWidth: 224,
            surfaceHeight: 64,
            surfaceScale: 1,
            contentMode: .cellPayloadPreferred)))
    }

    let initialOutput = (1...8).map { "old-\($0)" }.joined(separator: "\r\n") + "\r\n"
    XCTAssertEqual(session.feedOutput(Array(initialOutput.utf8)), 0)
    _ = try makeFrame(1, forceFull: true)
    XCTAssertEqual(session.markRendered(), 0)
    let before = try XCTUnwrap(session.viewportState()).viewportOffset

    XCTAssertEqual(session.feedOutput(Array("new-bottom-line\r\n".utf8)), 0)
    let next = try makeFrame(2, forceFull: false)
    let after = try XCTUnwrap(session.viewportState()).viewportOffset
    XCTAssertGreaterThan(after, before, "test setup must move the bottom-following viewport")

    guard case .full = next.damage else {
      XCTFail("viewport offset changes must force full damage, got \(next.damage)")
      return
    }
    XCTAssertEqual(next.cellPayload?.dirtyRows, Array(0..<Int(size.rows)))
  }

  func testScrollbackReturnToBottomForcesFullDamageAfterRenderedHistoryFrame() throws {
    var size = LabanTerminalSize()
    size.rows = 5
    size.cols = 32
    let model = try AppModel(initialSize: size)
    let tab = try XCTUnwrap(model.activeTab)
    let session = try XCTUnwrap(model.session(forTab: tab.id))
    let controller = TerminalSurfaceController(
      model: model,
      cellWidth: 8,
      cellHeight: 16,
      sidebarWidth: 0)

    func makeFrame(_ frame: Int, forceFull: Bool) throws -> TerminalSurfaceFrame {
      try XCTUnwrap(
        controller.makeFrame(
          TerminalSurfaceFrameRequest(
            frame: frame,
            viewportWidth: 256,
            viewportHeight: 80,
            requireActiveSnapshot: true,
            forceFullDamage: forceFull,
            surfaceWidth: 256,
            surfaceHeight: 80,
            surfaceScale: 1,
            contentMode: .cellPayloadPreferred)))
    }

    let history = (0..<80).map { "line-\($0)" }.joined(separator: "\r\n") + "\r\n"
    XCTAssertEqual(session.feedOutput(Array(history.utf8)), 0)
    _ = try makeFrame(1, forceFull: true)
    XCTAssertEqual(session.markRendered(), 0)

    XCTAssertEqual(session.scrollViewport(deltaRows: -20), 0)
    let scrolledFrame = try makeFrame(2, forceFull: false)
    guard case .full = scrolledFrame.damage else {
      XCTFail("scrolling into history must force full damage, got \(scrolledFrame.damage)")
      return
    }
    XCTAssertEqual(session.markRendered(), 0)

    XCTAssertGreaterThan(session.scrollViewportToActiveBottom(), 0)
    let bottomFrame = try makeFrame(3, forceFull: false)
    guard case .full = bottomFrame.damage else {
      XCTFail("returning to bottom must force full damage, got \(bottomFrame.damage)")
      return
    }
    XCTAssertEqual(bottomFrame.cellPayload?.dirtyRows, Array(0..<Int(size.rows)))
    XCTAssertFalse(bottomFrame.cellPayload?.glyphs.isEmpty ?? true)
  }

  func testCaptureCommandStreamIgnoresCellPayloadPreference() throws {
    func capturedCommands(
      contentMode: TerminalSurfaceFrameContentMode
    ) throws -> (commands: [String], returnedPayload: TerminalCellPayload?) {
      var size = LabanTerminalSize()
      size.rows = 4
      size.cols = 40
      let model = try AppModel(initialSize: size)
      let tab = try XCTUnwrap(model.activeTab)
      let session = try XCTUnwrap(model.session(forTab: tab.id))

      _ = session.write(Array("\u{1B}[4mhello\u{1B}[0m capture\r\n".utf8))
      _ = session.poll()

      let sink = RecordingSurfaceCaptureSink()
      let controller = TerminalSurfaceController(
        model: model,
        cellWidth: 8,
        cellHeight: 16,
        sidebarWidth: 200,
        captureSink: sink)
      let frame = try XCTUnwrap(
        controller.makeFrame(
          TerminalSurfaceFrameRequest(
            frame: 1,
            viewportWidth: 520,
            viewportHeight: 64,
            now: Date(timeIntervalSince1970: 1_234),
            reduceMotion: true,
            requireActiveSnapshot: true,
            surfaceWidth: 520,
            surfaceHeight: 64,
            surfaceScale: 1,
            contentMode: contentMode)))

      XCTAssertEqual(sink.frameCommands.count, 1)
      return (commandKeys(try XCTUnwrap(sink.frameCommands.first)), frame.cellPayload)
    }

    let classic = try capturedCommands(contentMode: .commands)
    let payloadPreferred = try capturedCommands(contentMode: .cellPayloadPreferred)

    XCTAssertNil(classic.returnedPayload)
    XCTAssertNil(payloadPreferred.returnedPayload)
    XCTAssertEqual(payloadPreferred.commands, classic.commands)
  }

  func testCellPayloadModeKeepsTextDecorationsOnPayloadPath() throws {
    var size = LabanTerminalSize()
    size.rows = 4
    size.cols = 80
    let model = try AppModel(initialSize: size)
    let tab = try XCTUnwrap(model.activeTab)
    let session = try XCTUnwrap(model.session(forTab: tab.id))

    let line =
      "\u{1B}[4mUL\u{1B}[0m "
      + "\u{1B}[9mSTRK\u{1B}[0m "
      + "\u{1B}[53mOVR\u{1B}[0m\r\n"
    _ = session.write(Array(line.utf8))
    _ = session.poll()

    let controller = TerminalSurfaceController(
      model: model,
      cellWidth: 8,
      cellHeight: 16,
      sidebarWidth: 200)
    let frame = try XCTUnwrap(
      controller.makeFrame(
        TerminalSurfaceFrameRequest(
          frame: 1,
          viewportWidth: 840,
          viewportHeight: 64,
          requireActiveSnapshot: true,
          surfaceWidth: 840,
          surfaceHeight: 64,
          surfaceScale: 1,
          contentMode: .cellPayloadPreferred)))

    let payload = try XCTUnwrap(frame.cellPayload)
    XCTAssertNil(payload.fallbackReason)
    XCTAssertTrue(payload.glyphs.contains { $0.attributes.contains(.underline) })
    XCTAssertTrue(payload.glyphs.contains { $0.attributes.contains(.strikethrough) })
    XCTAssertTrue(payload.glyphs.contains { $0.attributes.contains(.overline) })
    let terminalGlyphCommands = frame.commands.filter { command in
      if case .glyphRun(_, _, _, _, _, let source, _, _, _, _, _, _, _) = command {
        return source == .terminal
      }
      return false
    }
    XCTAssertTrue(terminalGlyphCommands.isEmpty)
  }

  func testCellPayloadModeKeepsProceduralCellsOnPayloadPath() throws {
    var size = LabanTerminalSize()
    size.rows = 4
    size.cols = 40
    let model = try AppModel(initialSize: size)
    let tab = try XCTUnwrap(model.activeTab)
    let session = try XCTUnwrap(model.session(forTab: tab.id))

    _ = session.write(Array("█▀▄▌▐░▓▖▚▟◢◣◤◥".utf8))
    _ = session.poll()

    let controller = TerminalSurfaceController(
      model: model,
      cellWidth: 8,
      cellHeight: 16,
      sidebarWidth: 200)
    let frame = try XCTUnwrap(
      controller.makeFrame(
        TerminalSurfaceFrameRequest(
          frame: 1,
          viewportWidth: 520,
          viewportHeight: 64,
          requireActiveSnapshot: true,
          surfaceWidth: 520,
          surfaceHeight: 64,
          surfaceScale: 1,
          contentMode: .cellPayloadPreferred)))

    let payload = try XCTUnwrap(frame.cellPayload)
    XCTAssertNil(payload.fallbackReason)
    XCTAssertFalse(payload.proceduralCells.isEmpty)
    let terminalCommands = frame.commands.filter { command in
      switch command {
      case .rect(_, _, let source, _),
        .glyphRun(_, _, _, _, _, let source, _, _, _, _, _, _, _):
        return source == .terminal
      default:
        return false
      }
    }
    XCTAssertTrue(terminalCommands.isEmpty)
  }

  func testCellPayloadModeKeepsHyperlinksOnPayloadPath() throws {
    var size = LabanTerminalSize()
    size.rows = 4
    size.cols = 80
    let model = try AppModel(initialSize: size)
    let tab = try XCTUnwrap(model.activeTab)
    let session = try XCTUnwrap(model.session(forTab: tab.id))

    let esc = "\u{1b}"
    let st = "\u{1b}\\"
    let bytes =
      "go "
      + "\(esc)]8;;https://example.com\(st)example.com\(esc)]8;;\(st)"
      + " done\r\n"
    _ = session.write(Array(bytes.utf8))
    _ = session.poll()

    let controller = TerminalSurfaceController(
      model: model,
      cellWidth: 8,
      cellHeight: 16,
      sidebarWidth: 200)
    let frame = try XCTUnwrap(
      controller.makeFrame(
        TerminalSurfaceFrameRequest(
          frame: 1,
          viewportWidth: 840,
          viewportHeight: 64,
          requireActiveSnapshot: true,
          surfaceWidth: 840,
          surfaceHeight: 64,
          surfaceScale: 1,
          contentMode: .cellPayloadPreferred)))

    let payload = try XCTUnwrap(frame.cellPayload)
    XCTAssertNil(payload.fallbackReason)
    XCTAssertTrue(payload.glyphs.contains { $0.hasHyperlink })
    XCTAssertTrue(payload.glyphs.contains { $0.hasHyperlink && $0.attributes.contains(.underline) })
    let terminalCommands = frame.commands.filter { command in
      if case .glyphRun(_, _, _, _, _, let source, _, _, _, _, _, _, _) = command {
        return source == .terminal
      }
      return false
    }
    XCTAssertTrue(terminalCommands.isEmpty)
  }

  func testCellPayloadModeReusesWarmCapacity() throws {
    var size = LabanTerminalSize()
    size.rows = 4
    size.cols = 20
    let model = try AppModel(initialSize: size)
    let session = try XCTUnwrap(model.activeTab.flatMap { model.session(forTab: $0.id) })

    _ = session.write(Array("hello".utf8))
    _ = session.poll()

    let controller = TerminalSurfaceController(
      model: model,
      cellWidth: 8,
      cellHeight: 16,
      sidebarWidth: 200)
    let request = TerminalSurfaceFrameRequest(
      frame: 1,
      viewportWidth: 360,
      viewportHeight: 64,
      requireActiveSnapshot: true,
      surfaceWidth: 360,
      surfaceHeight: 64,
      surfaceScale: 1,
      contentMode: .cellPayloadPreferred)

    _ = try XCTUnwrap(controller.makeFrame(request))
    let warmed = controller.cellPayloadCapacitySnapshotForTesting
    _ = try XCTUnwrap(controller.makeFrame(request))
    XCTAssertEqual(controller.cellPayloadCapacitySnapshotForTesting, warmed)
  }

  func testCellPayloadModeDecodesSingleUTF8ScalarWithoutTextMaterialization() throws {
    var size = LabanTerminalSize()
    size.rows = 4
    size.cols = 20
    let model = try AppModel(initialSize: size)
    let session = try XCTUnwrap(model.activeTab.flatMap { model.session(forTab: $0.id) })

    _ = session.write(Array("é".utf8))
    _ = session.poll()

    let controller = TerminalSurfaceController(
      model: model,
      cellWidth: 8,
      cellHeight: 16,
      sidebarWidth: 200)
    let frame = try XCTUnwrap(
      controller.makeFrame(
        TerminalSurfaceFrameRequest(
          frame: 1,
          viewportWidth: 360,
          viewportHeight: 64,
          requireActiveSnapshot: true,
          surfaceWidth: 360,
          surfaceHeight: 64,
          surfaceScale: 1,
          contentMode: .cellPayloadPreferred)))

    let glyph = try XCTUnwrap(frame.cellPayload?.glyphs.first { $0.scalarValue == 0xE9 })
    XCTAssertNil(glyph.utf8Range)
    XCTAssertNil(frame.cellPayload?.fallbackReason)
  }

  func testCellPayloadKeepsClusterTextInUTF8SlabOnPayloadPath() throws {
    var size = LabanTerminalSize()
    size.rows = 4
    size.cols = 20
    let session = try Session.fixture(size: size)
    defer { session.close() }

    _ = session.write(Array("👩‍💻".utf8))
    _ = session.poll()
    let snap = try XCTUnwrap(session.snapshot())
    defer { laban_snapshot_destroy(snap) }

    let producer = FrameProducer(cellWidth: 8, cellHeight: 16, originX: 0, originY: 0)
    let payload = try XCTUnwrap(
      producer.terminalCellPayload(
        from: UnsafePointer(snap),
        includedRows: [0],
        cursorBlinkVisible: false))

    XCTAssertNil(payload.fallbackReason)
    XCTAssertFalse(payload.utf8Bytes.isEmpty)
    let clusterTexts = payload.glyphs.compactMap { glyph -> String? in
      guard let range = glyph.utf8Range else { return nil }
      return String(decoding: payload.utf8Bytes[range], as: UTF8.self)
    }
    XCTAssertTrue(clusterTexts.contains("👩‍💻"), "got cluster payloads \(clusterTexts)")
  }

  func testCellPayloadKeepsShortCombiningClusterInUTF8SlabOnPayloadPath() throws {
    var size = LabanTerminalSize()
    size.rows = 4
    size.cols = 20
    let session = try Session.fixture(size: size)
    defer { session.close() }

    // NFD "e" + combining acute = 3 UTF-8 bytes spanning 2 scalars: a valid
    // grapheme cluster that fits in <= 4 bytes. It must stay on the GPU-cell
    // payload path (kept in the UTF-8 slab), not be rejected as invalid UTF-8.
    _ = session.write(Array("e\u{0301}".utf8))
    _ = session.poll()
    let snap = try XCTUnwrap(session.snapshot())
    defer { laban_snapshot_destroy(snap) }

    let producer = FrameProducer(cellWidth: 8, cellHeight: 16, originX: 0, originY: 0)
    let payload = try XCTUnwrap(
      producer.terminalCellPayload(
        from: UnsafePointer(snap),
        includedRows: [0],
        cursorBlinkVisible: false))

    XCTAssertNil(payload.fallbackReason)
    XCTAssertFalse(payload.utf8Bytes.isEmpty)
    let clusterTexts = payload.glyphs.compactMap { glyph -> String? in
      guard let range = glyph.utf8Range else { return nil }
      return String(decoding: payload.utf8Bytes[range], as: UTF8.self)
    }
    XCTAssertTrue(clusterTexts.contains("e\u{0301}"), "got cluster payloads \(clusterTexts)")
  }

  func testCellPayloadModeKeepsWideGlyphsOnPayloadPath() throws {
    var size = LabanTerminalSize()
    size.rows = 4
    size.cols = 20
    let model = try AppModel(initialSize: size)
    let session = try XCTUnwrap(model.activeTab.flatMap { model.session(forTab: $0.id) })

    _ = session.write(Array("中文A\r\n".utf8))
    _ = session.poll()

    let controller = TerminalSurfaceController(
      model: model,
      cellWidth: 8,
      cellHeight: 16,
      sidebarWidth: 200)
    let frame = try XCTUnwrap(
      controller.makeFrame(
        TerminalSurfaceFrameRequest(
          frame: 1,
          viewportWidth: 360,
          viewportHeight: 64,
          requireActiveSnapshot: true,
          surfaceWidth: 360,
          surfaceHeight: 64,
          surfaceScale: 1,
          contentMode: .cellPayloadPreferred)))

    let payload = try XCTUnwrap(frame.cellPayload)
    XCTAssertNil(payload.fallbackReason)
    XCTAssertTrue(payload.glyphs.contains { $0.wide == UInt8(LABAN_CELL_WIDE_WIDE) })
    let terminalGlyphCommands = frame.commands.filter { command in
      if case .glyphRun(_, _, _, _, _, let source, _, _, _, _, _, _, _) = command {
        return source == .terminal
      }
      return false
    }
    XCTAssertTrue(terminalGlyphCommands.isEmpty)
  }

  func testCellPayloadModePreservesContentYOffsetOnPayloadPath() throws {
    var size = LabanTerminalSize()
    size.rows = 4
    size.cols = 20
    let model = try AppModel(initialSize: size)
    let session = try XCTUnwrap(model.activeTab.flatMap { model.session(forTab: $0.id) })

    _ = session.write(Array("hello\r\n".utf8))
    _ = session.poll()

    let controller = TerminalSurfaceController(
      model: model,
      cellWidth: 8,
      cellHeight: 16,
      sidebarWidth: 200)
    let frame = try XCTUnwrap(
      controller.makeFrame(
        TerminalSurfaceFrameRequest(
          frame: 1,
          viewportWidth: 360,
          viewportHeight: 64,
          contentYOffset: 3.5,
          requireActiveSnapshot: true,
          surfaceWidth: 360,
          surfaceHeight: 64,
          surfaceScale: 1,
          contentMode: .cellPayloadPreferred)))

    let payload = try XCTUnwrap(frame.cellPayload)
    XCTAssertNil(payload.fallbackReason)
    XCTAssertEqual(payload.contentYOffset, 3.5)
  }

  func testCellPayloadModeKeepsSelectionOverlayOnPayloadPath() throws {
    var size = LabanTerminalSize()
    size.rows = 4
    size.cols = 20
    let model = try AppModel(initialSize: size)
    let session = try XCTUnwrap(model.activeTab.flatMap { model.session(forTab: $0.id) })

    _ = session.write(Array("hello".utf8))
    _ = session.poll()

    let controller = TerminalSurfaceController(
      model: model,
      cellWidth: 8,
      cellHeight: 16,
      sidebarWidth: 200)
    let selection = TerminalSelection(
      sessionId: session.id,
      anchor: .init(row: 0, col: 0),
      focus: .init(row: 0, col: 2))
    let frame = try XCTUnwrap(
      controller.makeFrame(
        TerminalSurfaceFrameRequest(
          frame: 1,
          viewportWidth: 360,
          viewportHeight: 64,
          selection: selection,
          requireActiveSnapshot: true,
          surfaceWidth: 360,
          surfaceHeight: 64,
          surfaceScale: 1,
          contentMode: .cellPayloadPreferred)))

    let payload = try XCTUnwrap(frame.cellPayload)
    XCTAssertNil(payload.fallbackReason)
    XCTAssertTrue(payload.cursorRects.isEmpty)
    XCTAssertTrue(
      frame.overlayCommands.contains { command in
        if case .selection = command { return true }
        return false
      })
    XCTAssertTrue(
      frame.overlayCommands.contains { command in
        if case .cursor = command { return true }
        return false
      })
    let terminalCommands = frame.commands.filter { command in
      switch command {
      case .rect(_, _, let source, _),
        .glyphRun(_, _, _, _, _, let source, _, _, _, _, _, _, _):
        return source == .terminal
      default:
        return false
      }
    }
    XCTAssertTrue(terminalCommands.isEmpty)
  }

  func testCellPayloadModeKeepsFindOverlayOnPayloadPath() throws {
    var size = LabanTerminalSize()
    size.rows = 4
    size.cols = 32
    let model = try AppModel(initialSize: size)
    let session = try XCTUnwrap(model.activeTab.flatMap { model.session(forTab: $0.id) })

    _ = session.write(Array("apple banana apple\r\n".utf8))
    _ = session.poll()
    XCTAssertNotNil(model.startFind(sessionID: session.id, needle: "apple"))

    let controller = TerminalSurfaceController(
      model: model,
      cellWidth: 8,
      cellHeight: 16,
      sidebarWidth: 200)
    let frame = try XCTUnwrap(
      controller.makeFrame(
        TerminalSurfaceFrameRequest(
          frame: 1,
          viewportWidth: 456,
          viewportHeight: 64,
          requireActiveSnapshot: true,
          surfaceWidth: 456,
          surfaceHeight: 64,
          surfaceScale: 1,
          contentMode: .cellPayloadPreferred)))

    let payload = try XCTUnwrap(frame.cellPayload)
    XCTAssertNil(payload.fallbackReason)
    XCTAssertTrue(
      frame.overlayCommands.contains { command in
        if case .findMatch = command { return true }
        return false
      })
    XCTAssertTrue(
      frame.overlayCommands.contains { command in
        if case .findSelected = command { return true }
        return false
      })
    let terminalGlyphCommands = frame.commands.filter { command in
      if case .glyphRun(_, _, _, _, _, let source, _, _, _, _, _, _, _) = command {
        return source == .terminal
      }
      return false
    }
    XCTAssertTrue(terminalGlyphCommands.isEmpty)
  }

  func testSyncSessionsReportsDirtySessionsAndMarksOnlyInactiveRendered() throws {
    var size = LabanTerminalSize()
    size.rows = 4
    size.cols = 20
    let model = try AppModel(initialSize: size)
    let firstTab = try XCTUnwrap(model.activeTab)
    _ = try model.createTab()
    let secondTab = try XCTUnwrap(model.activeTab)
    model.selectTab(firstTab.id)

    let firstSession = try XCTUnwrap(model.session(forTab: firstTab.id))
    let secondSession = try XCTUnwrap(model.session(forTab: secondTab.id))
    _ = firstSession.markRendered()
    _ = secondSession.markRendered()

    _ = firstSession.feedOutput(Array("active".utf8))
    _ = secondSession.feedOutput(Array("inactive".utf8))

    let controller = TerminalSurfaceController(
      model: model,
      cellWidth: 8,
      cellHeight: 16,
      sidebarWidth: 200)
    let now = Date(timeIntervalSince1970: 42)
    let result = controller.syncSessions(
      captureFrame: 2,
      polling: .none,
      markInactiveDirtyRendered: true,
      noteOutputOnDirty: true,
      recordTitleChanges: false,
      now: now)

    XCTAssertEqual(result.activeTabId, firstTab.id)
    XCTAssertEqual(result.activeSessionId, firstSession.id)
    XCTAssertTrue(result.activeTerminalDirty)
    XCTAssertEqual(result.dirtySessionIds, Set([firstSession.id, secondSession.id]))
    XCTAssertTrue(result.modelChanged)
    XCTAssertTrue(firstSession.renderDirty(), "active session remains dirty for rendering")
    XCTAssertFalse(secondSession.renderDirty(), "inactive dirty session is marked rendered")

    let updatedSecond = try XCTUnwrap(model.tabs.first { $0.id == secondTab.id })
    XCTAssertEqual(updatedSecond.lastOutputAt, now)
    XCTAssertTrue(updatedSecond.titleMetadata.unseenOutput)
    XCTAssertEqual(updatedSecond.titleMetadata.activityState, .unseenOutput)
  }

  /// Regression test for execplans/active/sidebar-hover-preview.md's "paused
  /// video" bug: steady streaming output from a background tab must still
  /// invalidate the frame when that tab is the one currently hover-previewed,
  /// even though `noteSurfaceOutput`'s unseen-output transition (exercised
  /// above) is edge-triggered and stops reporting `modelChanged` after the
  /// first byte.
  func testSyncSessionsHoveredInactiveTabKeepsReportingModelChanged() throws {
    var size = LabanTerminalSize()
    size.rows = 4
    size.cols = 20
    let model = try AppModel(initialSize: size)
    let firstTab = try XCTUnwrap(model.activeTab)
    _ = try model.createTab()
    let secondTab = try XCTUnwrap(model.activeTab)
    model.selectTab(firstTab.id)

    let secondSession = try XCTUnwrap(model.session(forTab: secondTab.id))
    _ = secondSession.markRendered()

    let controller = TerminalSurfaceController(
      model: model,
      cellWidth: 8,
      cellHeight: 16,
      sidebarWidth: 200)

    // First byte: the unseen-output edge fires regardless of hover.
    _ = secondSession.feedOutput(Array("first".utf8))
    let edgeResult = controller.syncSessions(
      captureFrame: 1,
      polling: .none,
      markInactiveDirtyRendered: true,
      noteOutputOnDirty: true,
      recordTitleChanges: false)
    XCTAssertTrue(edgeResult.modelChanged, "the unseen-output transition itself must invalidate")

    // Steady streaming with nothing hovering it: must NOT keep invalidating
    // (this is the existing perf guard `noteSurfaceOutput` documents; a
    // regression here would resurrect the per-output-tick cost it was added
    // to avoid).
    _ = secondSession.feedOutput(Array("second".utf8))
    let steadyResult = controller.syncSessions(
      captureFrame: 2,
      polling: .none,
      markInactiveDirtyRendered: true,
      noteOutputOnDirty: true,
      recordTitleChanges: false)
    XCTAssertFalse(
      steadyResult.modelChanged,
      "steady background streaming with no hover must stay silent (perf guard)")

    // Same steady streaming, but the tab is now hover-previewed: must
    // invalidate on every tick so the preview panel stays live.
    _ = secondSession.feedOutput(Array("third".utf8))
    let hoveredResult = controller.syncSessions(
      captureFrame: 3,
      polling: .none,
      markInactiveDirtyRendered: true,
      noteOutputOnDirty: true,
      recordTitleChanges: false,
      hoveredTabId: secondTab.id)
    XCTAssertTrue(
      hoveredResult.modelChanged,
      "a hovered background tab's continued output must invalidate the frame")
  }

  func testSyncSessionsRecordsResolvedTerminalTitleChanges() throws {
    var size = LabanTerminalSize()
    size.rows = 4
    size.cols = 20
    let model = try AppModel(initialSize: size)
    let tab = try XCTUnwrap(model.activeTab)
    let session = try XCTUnwrap(model.session(forTab: tab.id))
    let sink = RecordingSurfaceCaptureSink()
    let controller = TerminalSurfaceController(
      model: model,
      cellWidth: 8,
      cellHeight: 16,
      sidebarWidth: 200,
      captureSink: sink)

    _ = session.feedOutput(Array("\u{1B}]0;vim\u{07}".utf8))
    let result = controller.syncSessions(
      captureFrame: 3,
      polling: .none,
      markInactiveDirtyRendered: false,
      noteOutputOnDirty: false)

    XCTAssertTrue(result.modelChanged)
    XCTAssertEqual(model.tabs.first?.title, "vim")
    XCTAssertEqual(model.tabs.first?.titleMetadata.titleSource, .terminal)
    XCTAssertEqual(sink.events.count, 1)
    XCTAssertEqual(sink.events.first?.kind, CaptureEventKind.appState.rawValue)
    XCTAssertEqual(sink.events.first?.tabId, tab.id)
    XCTAssertEqual(sink.events.first?.sessionId, session.id)
    XCTAssertEqual(sink.events.first?.title, "vim")
  }

  func testVisibleTextSupportsTrimmedAndFullGridModes() throws {
    var size = LabanTerminalSize()
    size.rows = 2
    size.cols = 5
    let session = try Session.fixture(size: size)
    defer { session.close() }

    _ = session.write(Array("hi".utf8))
    _ = session.poll()

    guard let snap = session.snapshot() else {
      XCTFail("missing snapshot")
      return
    }
    defer { laban_snapshot_destroy(snap) }

    XCTAssertEqual(
      TerminalSnapshotText.visibleText(from: UnsafePointer(snap), mode: .trimmedNonEmptyRows),
      "hi")

    let fullGrid = TerminalSnapshotText.visibleText(from: UnsafePointer(snap), mode: .fullGrid)
    let lines = fullGrid.components(separatedBy: "\n")
    XCTAssertEqual(lines.count, 2)
    XCTAssertEqual(lines.first, "hi   ")
    XCTAssertEqual(lines.last, "     ")
  }

  func testDirtyRowDamageMapsTopDownRowsToBottomUpYRanges() {
    let dirtyRows: [UInt8] = [0, 1, 1, 0]
    var snapshot = LabanSnapshot()
    snapshot.rows = 4
    snapshot.dirty_row_count = 4

    let damage = dirtyRows.withUnsafeBufferPointer { buffer -> RenderDamage in
      snapshot.dirty_rows = buffer.baseAddress
      return withUnsafePointer(to: &snapshot) { ptr in
        TerminalSurfaceController.damage(
          snapshot: ptr,
          forceFull: false,
          cellHeight: 5,
          originY: 10)
      }
    }

    XCTAssertEqual(damage, .partial(yRanges: [DirtyYRange(y: 15, height: 10)]))
  }

  func testGloballyDirtySnapshotWithNoRowBitsForcesFullDamage() {
    let dirtyRows: [UInt8] = [0, 0, 0, 0]
    var snapshot = LabanSnapshot()
    snapshot.rows = 4
    snapshot.dirty = 1
    snapshot.dirty_row_count = 4

    let damage = dirtyRows.withUnsafeBufferPointer { buffer -> RenderDamage in
      snapshot.dirty_rows = buffer.baseAddress
      return withUnsafePointer(to: &snapshot) { ptr in
        TerminalSurfaceController.damage(
          snapshot: ptr,
          forceFull: false,
          cellHeight: 5,
          originY: 10)
      }
    }

    XCTAssertEqual(
      damage,
      .full,
      "a globally dirty snapshot with no row-local bits cannot safely preserve a Metal target")
  }

  func testFreshnessBandsIgnoreGloballyDirtySnapshotsWithNoRowBits() {
    let dirtyRows: [UInt8] = [0, 0, 0, 0]
    var snapshot = LabanSnapshot()
    snapshot.rows = 4
    snapshot.dirty = 1
    snapshot.dirty_row_count = 4

    let bands = dirtyRows.withUnsafeBufferPointer { buffer -> [DirtyYRange]? in
      snapshot.dirty_rows = buffer.baseAddress
      return withUnsafePointer(to: &snapshot) { ptr in
        TerminalSurfaceController.freshnessBands(
          snapshot: ptr,
          cellHeight: 5,
          originY: 10)
      }
    }

    XCTAssertNil(
      bands,
      "ambiguous global dirty must not invent whole-grid freshness for keystroke impulse")
  }

  func testFreshnessFallsBackToCursorCellWhenAllRowBitsAreSet() {
    let dirtyRows: [UInt8] = [1, 1, 1, 1]
    var snapshot = LabanSnapshot()
    snapshot.rows = 4
    snapshot.dirty = 1
    snapshot.dirty_row_count = 4
    snapshot.cursor_row = 2
    snapshot.cursor_col = 5

    let region = dirtyRows.withUnsafeBufferPointer { buffer -> GlyphEffectFreshness? in
      snapshot.dirty_rows = buffer.baseAddress
      return withUnsafePointer(to: &snapshot) { ptr in
        TerminalSurfaceController.freshness(
          snapshot: ptr,
          cellWidth: 8,
          cellHeight: 5,
          originX: 100,
          originY: 10)
      }
    }

    // Cursor row 2, cell before cursor (col 4): y = originY + (4-1-2)*5 = 15.
    XCTAssertEqual(region?.bands, [DirtyYRange(y: 15, height: 5)])
    XCTAssertEqual(region?.xMin, 100 + 4 * 8)
    XCTAssertEqual(region?.xMax, 100 + 5 * 8)
  }

  func testFreshnessUsesPreviousWholeRowWhenCoarseDirtyAndCursorColIsZero() {
    let dirtyRows: [UInt8] = [1, 1, 1, 1]
    var snapshot = LabanSnapshot()
    snapshot.rows = 4
    snapshot.dirty = 1
    snapshot.dirty_row_count = 4
    snapshot.cursor_row = 2
    snapshot.cursor_col = 0

    let region = dirtyRows.withUnsafeBufferPointer { buffer -> GlyphEffectFreshness? in
      snapshot.dirty_rows = buffer.baseAddress
      return withUnsafePointer(to: &snapshot) { ptr in
        TerminalSurfaceController.freshness(
          snapshot: ptr,
          cellWidth: 8,
          cellHeight: 5,
          originX: 100,
          originY: 10)
      }
    }

    // Previous row 1: y = originY + (4-1-1)*5 = 20. Whole-run (no X strip).
    XCTAssertEqual(region?.bands, [DirtyYRange(y: 20, height: 5)])
    XCTAssertNil(region?.xMin)
    XCTAssertNil(region?.xMax)
  }

  func testCellFingerprintIgnoresColorOnlyChanges() {
    var cell = LabanCell()
    cell.utf8_offset = 0
    cell.utf8_length = 1
    cell.wide = UInt8(LABAN_CELL_WIDE_NARROW)
    cell.foreground_rgba = 0xFF00_00FF
    let storage = "x"
    let a = storage.withCString { ptr in
      TerminalSurfaceController.cellContentFingerprint(cell: cell, storage: ptr)
    }
    cell.foreground_rgba = 0xFFFF_FFFF
    cell.flags = 0x20  // bold / intensity bit — must not affect bloom freshness
    let b = storage.withCString { ptr in
      TerminalSurfaceController.cellContentFingerprint(cell: cell, storage: ptr)
    }
    XCTAssertEqual(a, b, "spinner color/intensity pulses must not restart keystroke impulse")
  }

  func testFreshnessFromCellDiffBloomsOnlyChangedColumnsOnPromptRow() {
    // Prompt cells unchanged, only the typed column flipped → X strip.
    let previous: [Int: [UInt64]] = [31: [1, 1, 1, 1, 1, 1, 1, 1]]
    let current: [Int: [UInt64]] = [31: [1, 1, 1, 1, 1, 9, 1, 1]]
    let region = TerminalSurfaceController.freshnessFromCellDiff(
      dirtyRows: [31],
      currentFingerprints: current,
      previousFingerprints: previous,
      cols: 8,
      cellWidth: 10,
      cellHeight: 16,
      originX: 100,
      originY: 0,
      totalRows: 32)
    XCTAssertEqual(region?.bands, [DirtyYRange(y: 0, height: 16)])
    XCTAssertEqual(region?.xMin, 100 + 5 * 10)
    XCTAssertEqual(region?.xMax, 100 + 6 * 10)
    XCTAssertEqual(region?.mode, .cellDiff)
    XCTAssertEqual(region?.stripColMin, 5)
    XCTAssertEqual(region?.stripColMax, 5)
    XCTAssertEqual(region?.changedCells, 1)
  }

  func testStampedGlyphCountsCountsOnlyTimestampedTerminalRuns() {
    let commands: [FrameCommand] = [
      .glyphRun(
        origin: .zero, text: "hello", foreground: 0, background: 0, attributes: [],
        source: .terminal, outputTimestampSeconds: 1.0),
      .glyphRun(
        origin: .zero, text: "prompt", foreground: 0, background: 0, attributes: [],
        source: .terminal, outputTimestampSeconds: nil),
      .glyphRun(
        origin: .zero, text: "x", foreground: 0, background: 0, attributes: [],
        source: .sidebar, outputTimestampSeconds: 1.0),
    ]
    let counts = TerminalSurfaceController.stampedGlyphCounts(commands)
    XCTAssertEqual(counts.runs, 1)
    XCTAssertEqual(counts.glyphs, 5)
  }

  func testFreshnessFromCellDiffWholeRunsMultiRowBulk() {
    let previous: [Int: [UInt64]] = [
      10: [1, 1, 1, 1],
      11: [1, 1, 1, 1],
    ]
    let current: [Int: [UInt64]] = [
      10: [2, 1, 1, 1],
      11: [1, 2, 1, 1],
    ]
    let region = TerminalSurfaceController.freshnessFromCellDiff(
      dirtyRows: [10, 11],
      currentFingerprints: current,
      previousFingerprints: previous,
      cols: 4,
      cellWidth: 8,
      cellHeight: 12,
      originX: 0,
      originY: 0,
      totalRows: 20)
    XCTAssertNil(region?.xMin, "multi-row dumps classify as wholeRun, not cell-strip")
    XCTAssertEqual(region?.mode, .wholeRun)
    XCTAssertEqual(region?.changedCells, 2, "diff still counts real content changes")
    XCTAssertEqual(region?.bands.count, 2)
  }

  func testWholeRunBulkRewriteIsSuppressedThroughMakeFrame() throws {
    // Near-full-row lexical rewrite → freshness.mode == .wholeRun → stamp
    // path must leave every terminal run unstamped (btop-style bulk redraw).
    var size = LabanTerminalSize()
    size.rows = 4
    size.cols = 20
    let model = try AppModel(initialSize: size)
    guard let tab = model.activeTab,
      let session = model.session(forTab: tab.id)
    else {
      XCTFail("missing active fixture session")
      return
    }

    let controller = TerminalSurfaceController(
      model: model,
      cellWidth: 8,
      cellHeight: 16,
      sidebarWidth: 200)
    var now = 1.0
    controller.outputStampClock = { now }
    func makeFrame(_ index: Int) -> TerminalSurfaceFrame? {
      controller.makeFrame(
        TerminalSurfaceFrameRequest(
          frame: index,
          viewportWidth: 360,
          viewportHeight: 64,
          requireActiveSnapshot: true,
          surfaceWidth: 360,
          surfaceHeight: 64,
          surfaceScale: 1,
          glyphEffectsEnabled: true))
    }

    // Seed cell fingerprints with a settled 16-cell line (threshold for
    // wholeRun on cols=20 is max(8, 10) = 10 changed columns).
    _ = session.write(Array("aaaaaaaaaaaaaaaa".utf8))
    _ = session.poll()
    XCTAssertNotNil(makeFrame(1))
    session.markRendered()

    // CR + rewrite the same span with different glyphs → one dirty row, many
    // changed columns → wholeRun classification → suppress.
    _ = session.write(Array("\rbbbbbbbbbbbbbbbb".utf8))
    _ = session.poll()
    now = 2.0
    guard let frame = makeFrame(2) else {
      XCTFail("expected a frame after bulk rewrite")
      return
    }
    XCTAssertEqual(
      frame.glyphEffectStamp?.mode, .wholeRun,
      "bulk lexical rewrite must classify as wholeRun")
    XCTAssertEqual(frame.glyphEffectStamp?.stampedGlyphs, 0)
    XCTAssertEqual(frame.glyphEffectStamp?.stampedRuns, 0)
    let stamps = terminalGlyphRunTimestamps(frame)
    XCTAssertTrue(
      stamps.allSatisfy { $0.stamp == nil },
      "wholeRun suppress must not stamp any terminal glyph run; got \(stamps)")
  }

  func testCellStripStampSplitsCoalescedRunSoOnlyFreshCharacterBlooms() {
    let run = FrameCommand.glyphRun(
      origin: CGPoint(x: 100, y: 20),
      text: "hello",
      foreground: 0xFFFF_FFFF,
      background: 0,
      attributes: [],
      source: .terminal)
    // Fresh strip covers the final 'o' (col offset 4 from grid origin 100).
    let stamped = TerminalSurfaceController.applyCellStripStamp(
      [run],
      bands: [DirtyYRange(y: 20, height: 16)],
      xMin: 100 + 4 * 8,
      xMax: 100 + 5 * 8,
      cellWidth: 8,
      cellHeight: 16,
      gridOriginX: 100,
      stamp: 3.5)
    let pieces = stamped.compactMap { command -> (String, Double?)? in
      guard case .glyphRun(_, let text, _, _, _, .terminal, _, _, _, _, let stamp, _, _) = command
      else { return nil }
      return (text, stamp)
    }
    XCTAssertEqual(pieces.map(\.0), ["hell", "o"])
    XCTAssertEqual(pieces.map(\.1), [nil, 3.5])
  }

  func testFreshnessBandsKeepSubsetDirtyRowsPrecise() {
    let dirtyRows: [UInt8] = [0, 1, 1, 0]
    var snapshot = LabanSnapshot()
    snapshot.rows = 4
    snapshot.dirty = 1
    snapshot.dirty_row_count = 4
    snapshot.cursor_row = 3

    let bands = dirtyRows.withUnsafeBufferPointer { buffer -> [DirtyYRange]? in
      snapshot.dirty_rows = buffer.baseAddress
      return withUnsafePointer(to: &snapshot) { ptr in
        TerminalSurfaceController.freshnessBands(
          snapshot: ptr,
          cellHeight: 5,
          originY: 10)
      }
    }

    XCTAssertEqual(
      bands,
      [DirtyYRange(y: 15, height: 10)],
      "a precise dirty subset must not collapse to the cursor row")
  }

  func testRemoteDirtyRangesMapTopDownRowsToBottomUpYRanges() {
    let damage = TerminalSurfaceController.damage(
      rows: 5,
      dirtyRanges: [
        LabandSnapshotDirtyRange(startRow: 1, endRow: 3),
        LabandSnapshotDirtyRange(startRow: 4, endRow: 5),
      ],
      forceFull: false,
      cellHeight: 6,
      originY: 10)

    XCTAssertEqual(
      damage,
      .partial(yRanges: [
        DirtyYRange(y: 22, height: 12),
        DirtyYRange(y: 10, height: 6),
      ]))
  }

  // MARK: - Generation gating tests

  func testGenerationGatingSkipsMetadataSyncOnUnchangedGeneration() throws {
    // Two consecutive syncSessions calls with no writes between them must run
    // per-tab sync work exactly once: the first call populates the generation
    // cache; the second call observes the same generation and skips.
    var size = LabanTerminalSize()
    size.rows = 4
    size.cols = 20
    let model = try AppModel(initialSize: size)
    let controller = TerminalSurfaceController(
      model: model,
      cellWidth: 8,
      cellHeight: 16,
      sidebarWidth: 200)

    // First call — generation unknown, sync runs.
    _ = controller.syncSessions(
      captureFrame: 1,
      polling: .none,
      markInactiveDirtyRendered: false,
      noteOutputOnDirty: false)
    let afterFirst = controller.metadataSyncCountForTesting

    // Second call — generation unchanged, sync must be skipped.
    _ = controller.syncSessions(
      captureFrame: 2,
      polling: .none,
      markInactiveDirtyRendered: false,
      noteOutputOnDirty: false)
    XCTAssertEqual(
      controller.metadataSyncCountForTesting, afterFirst,
      "unchanged generation must skip metadata sync on the second tick")
  }

  func testGenerationGatingRunsSyncAfterWrite() throws {
    // Writing bytes to a session advances the dirty generation; the next
    // syncSessions must run per-tab sync work again.
    var size = LabanTerminalSize()
    size.rows = 4
    size.cols = 20
    let model = try AppModel(initialSize: size)
    let tab = try XCTUnwrap(model.activeTab)
    let session = try XCTUnwrap(model.session(forTab: tab.id))
    let controller = TerminalSurfaceController(
      model: model,
      cellWidth: 8,
      cellHeight: 16,
      sidebarWidth: 200)

    // Warm the cache.
    _ = controller.syncSessions(
      captureFrame: 1,
      polling: .none,
      markInactiveDirtyRendered: false,
      noteOutputOnDirty: false)
    let afterWarm = controller.metadataSyncCountForTesting

    // Write bytes — advances the generation.
    _ = session.feedOutput(Array("hello".utf8))

    // Next call must re-run sync work.
    _ = controller.syncSessions(
      captureFrame: 2,
      polling: .none,
      markInactiveDirtyRendered: false,
      noteOutputOnDirty: false)
    XCTAssertGreaterThan(
      controller.metadataSyncCountForTesting, afterWarm,
      "a write must advance the dirty generation and cause sync work to run")
  }

  func testGenerationGatingPreservesPublicAPISemantics() throws {
    // The five pre-existing sync tests are the oracle; this test verifies that
    // gating does not change the observable result compared to a fresh
    // (non-gated) call. We feed output on both sessions, run syncSessions, and
    // check the returned result is correct.
    var size = LabanTerminalSize()
    size.rows = 4
    size.cols = 20
    let model = try AppModel(initialSize: size)
    let firstTab = try XCTUnwrap(model.activeTab)
    _ = try model.createTab()
    let secondTab = try XCTUnwrap(model.activeTab)
    model.selectTab(firstTab.id)

    let firstSession = try XCTUnwrap(model.session(forTab: firstTab.id))
    let secondSession = try XCTUnwrap(model.session(forTab: secondTab.id))
    _ = firstSession.markRendered()
    _ = secondSession.markRendered()
    _ = firstSession.feedOutput(Array("active".utf8))
    _ = secondSession.feedOutput(Array("inactive".utf8))

    let controller = TerminalSurfaceController(
      model: model,
      cellWidth: 8,
      cellHeight: 16,
      sidebarWidth: 200)
    let now = Date(timeIntervalSince1970: 42)
    let result = controller.syncSessions(
      captureFrame: 2,
      polling: .none,
      markInactiveDirtyRendered: true,
      noteOutputOnDirty: true,
      recordTitleChanges: false,
      now: now)

    // Same assertions as testSyncSessionsReportsDirtySessionsAndMarksOnlyInactiveRendered.
    XCTAssertEqual(result.activeTabId, firstTab.id)
    XCTAssertTrue(result.activeTerminalDirty)
    XCTAssertEqual(result.dirtySessionIds, Set([firstSession.id, secondSession.id]))
    XCTAssertTrue(result.modelChanged)
    XCTAssertTrue(firstSession.renderDirty(), "active session remains dirty for rendering")
    XCTAssertFalse(secondSession.renderDirty(), "inactive dirty session is marked rendered")
    let updatedSecond = try XCTUnwrap(model.tabs.first { $0.id == secondTab.id })
    XCTAssertEqual(updatedSecond.lastOutputAt, now)
  }

  func testGenerationGatingFlipsTabExitStateAfterZeroOutputChildExit() throws {
    // Plan M1 step 5(d), end-to-end with a REAL exit (no feedOutput
    // simulation): the child exits with zero output → the registry's reader
    // thread drains EOF and pty_io.c bumps the dirty generation on the
    // status 0→nonzero transition → the next gated syncSessions sees the
    // generation advance, runs the sync cluster, and the tab's exit state
    // flips — within ONE syncSessions call.
    //
    // Mutation-killing property: with the pty_io.c exit bump disabled, the
    // generation never advances after the warm-up, the gated sync skips the
    // tab, and the final assertion fails because the tab stays .running.
    var size = LabanTerminalSize()
    size.rows = 4
    size.cols = 20
    // The child sleeps long enough for the warm-up sync below to run while
    // it is still alive, then exits emitting nothing.
    let model = try AppModel(initialSize: size) { size in
      try Session.realShell(
        size: size, launchArgv: ["/bin/sh", "-c", "sleep 0.5; exit 7"])
    }
    let tab = try XCTUnwrap(model.activeTab)
    let session = try XCTUnwrap(model.session(forTab: tab.id))
    let controller = TerminalSurfaceController(
      model: model,
      cellWidth: 8,
      cellHeight: 16,
      sidebarWidth: 200)

    // Warm the gating cache while the child is alive. Theme-palette
    // injection at session creation has already advanced the generation
    // past 0, so the gate is active (a 0 generation is treated as unknown
    // and bypasses gating, which would defeat the mutation-killing check).
    XCTAssertGreaterThan(
      session.dirtyGeneration(), 0,
      "setup: generation must be nonzero so gating is active")
    _ = controller.syncSessions(
      captureFrame: 1,
      polling: .none,
      markInactiveDirtyRendered: false,
      noteOutputOnDirty: false)
    XCTAssertEqual(
      model.tabs.first?.status, .running,
      "setup: the tab must still be running at warm-up time")

    // Wait for the registry's reader thread (the production drain path) to
    // observe the exit; exitState() reads the C status the drain sets.
    let deadline = Date().addingTimeInterval(5.0)
    while session.exitState() == .running && Date() < deadline {
      Thread.sleep(forTimeInterval: 0.02)
    }
    XCTAssertEqual(
      session.exitState(), .exited(code: 7),
      "setup: the child must have exited within the deadline")

    // ONE gated syncSessions call must flip the tab status: the exit bump
    // advanced the generation, so gating lets the sync cluster run.
    _ = controller.syncSessions(
      captureFrame: 2,
      polling: .none,
      markInactiveDirtyRendered: false,
      noteOutputOnDirty: false)
    XCTAssertEqual(
      model.tabs.first?.status, .exited(code: 7),
      "a zero-output child exit must flip the tab's exit state within one "
        + "gated syncSessions call (exit → generation bump → sync runs)")
  }

  // MARK: - Glyph-effect output stamping (per-glyph-animation-channel M1)

  private func terminalGlyphRunTimestamps(
    _ frame: TerminalSurfaceFrame
  ) -> [(text: String, stamp: Double?)] {
    frame.commands.compactMap { command in
      guard
        case .glyphRun(
          _, let text, _, _, _, let source, _, _, _, _, let stamp, _, _) = command,
        source == .terminal
      else { return nil }
      return (text, stamp)
    }
  }

  func testOutputStampingMarksOnlyFreshRowsWithStableTimestamp() throws {
    var size = LabanTerminalSize()
    size.rows = 4
    size.cols = 20
    let model = try AppModel(initialSize: size)
    guard let tab = model.activeTab,
      let session = model.session(forTab: tab.id)
    else {
      XCTFail("missing active fixture session")
      return
    }
    _ = session.write(Array("one\r\n".utf8))
    _ = session.poll()

    let controller = TerminalSurfaceController(
      model: model,
      cellWidth: 8,
      cellHeight: 16,
      sidebarWidth: 200)
    var now = 1.0
    controller.outputStampClock = { now }
    func makeFrame(_ index: Int) -> TerminalSurfaceFrame? {
      controller.makeFrame(
        TerminalSurfaceFrameRequest(
          frame: index,
          viewportWidth: 360,
          viewportHeight: 64,
          requireActiveSnapshot: true,
          surfaceWidth: 360,
          surfaceHeight: 64,
          surfaceScale: 1,
          glyphEffectsEnabled: true))
    }

    // First frame after output: the fresh run is stamped at the clock's now.
    guard let frame1 = makeFrame(1) else {
      XCTFail("expected a frame")
      return
    }
    let stamps1 = terminalGlyphRunTimestamps(frame1)
    XCTAssertEqual(stamps1.first(where: { $0.text == "one" })?.stamp ?? nil, 1.0)
    session.markRendered()

    // New output on the next row: only that row is stamped (exact-extent
    // band filter — the clean row above must not be re-stamped), at the new
    // clock time.
    _ = session.write(Array("two\r\n".utf8))
    _ = session.poll()
    now = 2.0
    guard let frame2 = makeFrame(2) else {
      XCTFail("expected a frame")
      return
    }
    let stamps2 = terminalGlyphRunTimestamps(frame2)
    XCTAssertEqual(
      stamps2.first(where: { $0.text == "one" })?.stamp ?? nil, nil,
      "a row untouched by the new output must keep a nil timestamp")
    XCTAssertEqual(stamps2.first(where: { $0.text == "two" })?.stamp ?? nil, 2.0)
    session.markRendered()

    // No new output, still inside the freshness window: the same stamp is
    // re-applied (effectStart stability across rebuilds).
    now = 2.1
    guard let frame3 = makeFrame(3) else {
      XCTFail("expected a frame")
      return
    }
    let stamps3 = terminalGlyphRunTimestamps(frame3)
    XCTAssertEqual(
      stamps3.first(where: { $0.text == "two" })?.stamp ?? nil, 2.0,
      "rebuilds inside the window must re-apply the original stamp")

    // Past the freshness window (maxDecaySeconds): stamping stops, so
    // re-emitted runs can never restart an effect.
    now = 2.1 + GlyphEffectTimeline.maxDecaySeconds + 0.01
    guard let frame4 = makeFrame(4) else {
      XCTFail("expected a frame")
      return
    }
    let stamps4 = terminalGlyphRunTimestamps(frame4)
    XCTAssertEqual(
      stamps4.first(where: { $0.text == "two" })?.stamp ?? nil, nil,
      "after the freshness window the stamp must expire")
  }

  func testKeystrokeDoesNotCutInFlightTypeInStampOnPreviousCell() throws {
    // Typing cadence (~100 ms) is shorter than the stamp retention horizon
    // (maxDecaySeconds, 300 ms), so the previous character's type-in effect
    // is still live when the next one lands. The new generation must not
    // drop the in-flight stamp: losing it snaps the previous glyph from
    // mid-animation to settled in one frame (a visible pop on the cell
    // before the cursor).
    var size = LabanTerminalSize()
    size.rows = 4
    size.cols = 20
    let model = try AppModel(initialSize: size)
    guard let tab = model.activeTab,
      let session = model.session(forTab: tab.id)
    else {
      XCTFail("missing active fixture session")
      return
    }

    let controller = TerminalSurfaceController(
      model: model,
      cellWidth: 8,
      cellHeight: 16,
      sidebarWidth: 200)
    var now = 1.0
    controller.outputStampClock = { now }
    func makeFrame(_ index: Int) -> TerminalSurfaceFrame? {
      controller.makeFrame(
        TerminalSurfaceFrameRequest(
          frame: index,
          viewportWidth: 360,
          viewportHeight: 64,
          requireActiveSnapshot: true,
          surfaceWidth: 360,
          surfaceHeight: 64,
          surfaceScale: 1,
          glyphEffectsEnabled: true))
    }

    // Keystroke 1: 'a' lands, cursor-cell strip stamps it at 1.0.
    _ = session.write(Array("a".utf8))
    _ = session.poll()
    guard let frame1 = makeFrame(1) else {
      XCTFail("expected a frame")
      return
    }
    let stamps1 = terminalGlyphRunTimestamps(frame1)
    XCTAssertEqual(stamps1.first(where: { $0.text == "a" })?.stamp ?? nil, 1.0)
    session.markRendered()

    // Keystroke 2, 100 ms later (mid-bloom for 'a'): 'b' is stamped at 1.1
    // while 'a' must keep its original 1.0 stamp so its bloom completes.
    _ = session.write(Array("b".utf8))
    _ = session.poll()
    now = 1.1
    guard let frame2 = makeFrame(2) else {
      XCTFail("expected a frame")
      return
    }
    let stamps2 = terminalGlyphRunTimestamps(frame2)
    XCTAssertEqual(
      stamps2.first(where: { $0.text == "a" })?.stamp ?? nil, 1.0,
      "the previous cell's in-flight bloom must survive the next keystroke")
    XCTAssertEqual(stamps2.first(where: { $0.text == "b" })?.stamp ?? nil, 1.1)
    session.markRendered()

    // Same generation, still inside both windows: both stamps re-apply.
    now = 1.2
    guard let frame3 = makeFrame(3) else {
      XCTFail("expected a frame")
      return
    }
    let stamps3 = terminalGlyphRunTimestamps(frame3)
    XCTAssertEqual(stamps3.first(where: { $0.text == "a" })?.stamp ?? nil, 1.0)
    XCTAssertEqual(stamps3.first(where: { $0.text == "b" })?.stamp ?? nil, 1.1)

    // Staggered expiry: 'a's window (1.0 + maxDecay) closes first; 'b' keeps
    // blooming on its own until its own window closes.
    now = 1.0 + GlyphEffectTimeline.maxDecaySeconds + 0.05
    guard let frame4 = makeFrame(4) else {
      XCTFail("expected a frame")
      return
    }
    let stamps4 = terminalGlyphRunTimestamps(frame4)
    XCTAssertEqual(stamps4.first(where: { $0.text == "a" })?.stamp ?? nil, nil)
    XCTAssertEqual(stamps4.first(where: { $0.text == "b" })?.stamp ?? nil, 1.1)

    now = 1.1 + GlyphEffectTimeline.maxDecaySeconds + 0.01
    guard let frame5 = makeFrame(5) else {
      XCTFail("expected a frame")
      return
    }
    let stamps5 = terminalGlyphRunTimestamps(frame5)
    XCTAssertEqual(stamps5.first(where: { $0.text == "b" })?.stamp ?? nil, nil)
  }

  func testForceFullDamageDoesNotStampSettledScrollback() throws {
    var size = LabanTerminalSize()
    size.rows = 6
    size.cols = 20
    let model = try AppModel(initialSize: size)
    guard let tab = model.activeTab,
      let session = model.session(forTab: tab.id)
    else {
      XCTFail("missing active fixture session")
      return
    }
    _ = session.write(Array("alpha\r\nbeta\r\ngamma\r\n".utf8))
    _ = session.poll()

    let controller = TerminalSurfaceController(
      model: model,
      cellWidth: 8,
      cellHeight: 16,
      sidebarWidth: 200)
    var now = 10.0
    controller.outputStampClock = { now }
    func makeFrame(_ index: Int, forceFull: Bool) -> TerminalSurfaceFrame? {
      controller.makeFrame(
        TerminalSurfaceFrameRequest(
          frame: index,
          viewportWidth: 360,
          viewportHeight: 96,
          requireActiveSnapshot: true,
          forceFullDamage: forceFull,
          surfaceWidth: 360,
          surfaceHeight: 96,
          surfaceScale: 1,
          glyphEffectsEnabled: true))
    }

    // Settle the first screenful so later frames only see the new row as fresh.
    guard let settle = makeFrame(1, forceFull: true) else {
      XCTFail("expected a settle frame")
      return
    }
    XCTAssertFalse(
      terminalGlyphRunTimestamps(settle).isEmpty,
      "expected terminal glyph runs on the settle frame")
    session.markRendered()

    _ = session.write(Array("delta\r\n".utf8))
    _ = session.poll()
    now = 11.0
    // forceFullDamage is the live path when renderInvalidated is set (effect
    // pumping, tab change, …). Freshness must still come from row bits — a
    // full redraw must not re-bloom settled scrollback.
    guard let frame = makeFrame(2, forceFull: true) else {
      XCTFail("expected a frame")
      return
    }
    let stamps = terminalGlyphRunTimestamps(frame)
    XCTAssertEqual(
      stamps.first(where: { $0.text == "alpha" })?.stamp ?? nil, nil,
      "settled scrollback must stay unstamped on a force-full redraw")
    XCTAssertEqual(
      stamps.first(where: { $0.text == "beta" })?.stamp ?? nil, nil,
      "settled scrollback must stay unstamped on a force-full redraw")
    XCTAssertEqual(
      stamps.first(where: { $0.text == "gamma" })?.stamp ?? nil, nil,
      "settled scrollback must stay unstamped on a force-full redraw")
    XCTAssertEqual(
      stamps.first(where: { $0.text == "delta" })?.stamp ?? nil, 11.0,
      "only the freshly output row may receive the keystroke-impulse stamp")
  }

  // MARK: - Spinner motion re-activation

  func testSpinnerMotionReactivatesAfterLiveToggle() throws {
    var size = LabanTerminalSize()
    size.rows = 1
    size.cols = 32
    let model = try AppModel(initialSize: size)
    guard let tab = model.activeTab,
      let session = model.session(forTab: tab.id)
    else {
      XCTFail("missing active fixture session")
      return
    }

    let controller = TerminalSurfaceController(
      model: model,
      cellWidth: 8,
      cellHeight: 16,
      sidebarWidth: 0)
    var virtualTime: Double = 0
    controller.outputStampClock = { virtualTime }

    let bullets = String(repeating: "\u{2022}", count: 20)
    func feed(red: Bool) {
      let color = red ? "255;0;0" : "0;0;255"
      let bytes = Array(
        "\u{001B}[?25l\u{001B}[H\u{001B}[38;2;\(color)m\(bullets)".utf8)
      _ = session.write(bytes)
      _ = session.poll()
    }

    func makeFrame(enabled: Bool, frame: Int) -> TerminalSurfaceFrame? {
      virtualTime += 0.3
      return controller.makeFrame(
        TerminalSurfaceFrameRequest(
          frame: frame,
          viewportWidth: 256,
          viewportHeight: 16,
          cursorBlinkVisible: false,
          requireActiveSnapshot: true,
          surfaceWidth: 256,
          surfaceHeight: 16,
          surfaceScale: 1,
          spinnerMotionSmoothingEnabled: enabled,
          effectiveRendererIsSlug: true))
    }

    // Warm up: three alternating color pulses should activate the detector.
    feed(red: true)
    let warm1 = makeFrame(enabled: true, frame: 1)
    XCTAssertEqual(warm1?.spinnerMotionDiagnostics?.activeTransitions ?? 0, 0)

    feed(red: false)
    let warm2 = makeFrame(enabled: true, frame: 2)
    XCTAssertEqual(warm2?.spinnerMotionDiagnostics?.activeTransitions ?? 0, 0)

    feed(red: true)
    let warm3 = makeFrame(enabled: true, frame: 3)
    XCTAssertTrue(warm3?.spinnerMotionDiagnostics?.detectorActive ?? false)
    XCTAssertGreaterThan(warm3?.spinnerMotionDiagnostics?.activeTransitions ?? 0, 0)

    // Toggle the setting off: detector state is dropped and no transitions are emitted.
    feed(red: false)
    let offFrame = makeFrame(enabled: false, frame: 4)
    XCTAssertEqual(offFrame?.spinnerMotionDiagnostics?.activeTransitions ?? 0, 0)

    // Toggle back on. The detector must re-learn the cadence from scratch and
    // re-activate on the third qualifying observation — this is what a user
    // sees after turning Smooth spinner motion off and on while a spinner runs.
    feed(red: true)
    let reactivate1 = makeFrame(enabled: true, frame: 5)
    XCTAssertEqual(reactivate1?.spinnerMotionDiagnostics?.activeTransitions ?? 0, 0)

    feed(red: false)
    let reactivate2 = makeFrame(enabled: true, frame: 6)
    XCTAssertEqual(reactivate2?.spinnerMotionDiagnostics?.activeTransitions ?? 0, 0)

    feed(red: true)
    let reactivate3 = makeFrame(enabled: true, frame: 7)
    XCTAssertTrue(reactivate3?.spinnerMotionDiagnostics?.detectorActive ?? false)
    XCTAssertGreaterThan(reactivate3?.spinnerMotionDiagnostics?.activeTransitions ?? 0, 0)

    // Continue pulsing: the re-activated detector must not be confused by the
    // earlier off/on switch and should keep producing transitions.
    feed(red: false)
    let reactivate4 = makeFrame(enabled: true, frame: 8)
    XCTAssertTrue(reactivate4?.spinnerMotionDiagnostics?.detectorActive ?? false)
    XCTAssertGreaterThan(reactivate4?.spinnerMotionDiagnostics?.activeTransitions ?? 0, 0)
  }
}
