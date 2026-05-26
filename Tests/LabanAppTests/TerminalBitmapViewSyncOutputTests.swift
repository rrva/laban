import AppKit
import Darwin
import LabanCore
import LabanRenderer
import LabanTerminalCore
import XCTest

@testable import LabanApp

final class TerminalBitmapViewSyncOutputTests: XCTestCase {

  func testSynchronizedOutputGateTimesOutStuckWindow() {
    let start = Date(timeIntervalSinceReferenceDate: 1_000)
    let first = TerminalRenderGate.synchronizedOutputDecision(
      terminalDirty: true,
      synchronizedOutputActive: true,
      sessionId: "session-1",
      now: start,
      hold: nil)
    XCTAssertEqual(
      first,
      TerminalRenderGate.SynchronizedOutputDecision(
        shouldDefer: true,
        shouldResetMode: false,
        hold: TerminalRenderGate.SynchronizedOutputHold(sessionId: "session-1", startedAt: start)))

    let beforeTimeout = TerminalRenderGate.synchronizedOutputDecision(
      terminalDirty: true,
      synchronizedOutputActive: true,
      sessionId: "session-1",
      now: start.addingTimeInterval(0.999),
      hold: first.hold)
    XCTAssertTrue(beforeTimeout.shouldDefer)
    XCTAssertFalse(beforeTimeout.shouldResetMode)
    XCTAssertEqual(beforeTimeout.hold, first.hold)

    let afterTimeout = TerminalRenderGate.synchronizedOutputDecision(
      terminalDirty: true,
      synchronizedOutputActive: true,
      sessionId: "session-1",
      now: start.addingTimeInterval(1.001),
      hold: first.hold)
    XCTAssertFalse(afterTimeout.shouldDefer)
    XCTAssertTrue(afterTimeout.shouldResetMode)
    XCTAssertNil(afterTimeout.hold)

    let reset = TerminalRenderGate.synchronizedOutputDecision(
      terminalDirty: true,
      synchronizedOutputActive: false,
      sessionId: "session-1",
      now: start,
      hold: first.hold)
    XCTAssertFalse(reset.shouldDefer)
    XCTAssertFalse(reset.shouldResetMode)
    XCTAssertNil(reset.hold)
  }

  func testOutputSettleGateDefersBrieflyAfterRecentDrain() {
    let start = Date(timeIntervalSinceReferenceDate: 1_000)
    let decision = TerminalRenderGate.outputSettleDecision(
      terminalDirty: true,
      sessionId: "session-1",
      lastDirtyAt: start,
      now: start.addingTimeInterval(0.004),
      hold: nil,
      quiet: 0.012,
      maxHold: 0.025)

    XCTAssertTrue(decision.shouldDefer)
    XCTAssertEqual(decision.hold?.sessionId, "session-1")
    XCTAssertEqual(decision.hold?.startedAt, start.addingTimeInterval(0.004))
    XCTAssertEqual(decision.wakeAfter ?? 0, 0.008, accuracy: 0.000_001)
  }

  func testOutputSettleGateRendersAfterQuietWindowOrMaxHold() {
    let start = Date(timeIntervalSinceReferenceDate: 1_000)
    let hold = TerminalRenderGate.OutputSettleHold(sessionId: "session-1", startedAt: start)

    let quietEnough = TerminalRenderGate.outputSettleDecision(
      terminalDirty: true,
      sessionId: "session-1",
      lastDirtyAt: start,
      now: start.addingTimeInterval(0.013),
      hold: hold,
      quiet: 0.012,
      maxHold: 0.025)
    XCTAssertFalse(quietEnough.shouldDefer)
    XCTAssertNil(quietEnough.hold)

    let maxHoldReached = TerminalRenderGate.outputSettleDecision(
      terminalDirty: true,
      sessionId: "session-1",
      lastDirtyAt: start.addingTimeInterval(0.020),
      now: start.addingTimeInterval(0.026),
      hold: hold,
      quiet: 0.012,
      maxHold: 0.025)
    XCTAssertFalse(maxHoldReached.shouldDefer)
    XCTAssertNil(maxHoldReached.hold)
  }

  func testOutputSettleQuietWindowIsShorterForRemoteSnapshotRanges() {
    XCTAssertEqual(
      TerminalRenderGate.settleQuietSeconds(
        remoteDirtyRanges: [LabandSnapshotDirtyRange(startRow: 2, endRow: 3)]),
      TerminalRenderGate.remoteSnapshotOutputSettleQuietSeconds)
    XCTAssertEqual(
      TerminalRenderGate.settleQuietSeconds(
        remoteDirtyRanges: [LabandSnapshotDirtyRange(startRow: 2, endRow: 8)]),
      TerminalRenderGate.remoteSnapshotOutputSettleQuietSeconds)
    XCTAssertEqual(
      TerminalRenderGate.settleQuietSeconds(remoteDirtyRanges: nil),
      TerminalRenderGate.outputSettleQuietSeconds)
  }

  func testRemoteSnapshotPublishTimeDoesNotRestartSettleWindowAtPollTime() throws {
    let now = Date(timeIntervalSinceReferenceDate: 1_000)
    let snapshot = LabandSnapshotResponse(
      logicalSessionId: "session-1",
      incarnationId: "incarnation-1",
      rows: 1,
      cols: 1,
      cursorRow: 0,
      cursorCol: 0,
      cursorVisible: true,
      title: "",
      lifecycleState: .running,
      exitStatus: nil,
      dirty: true,
      visibleText: "x",
      cells: [])
    let frame = LabandSnapshotFrame(
      generation: 1,
      snapshotPublishMonoNs: 1_000_000_000,
      snapshot: snapshot)

    let dirtyAt = try XCTUnwrap(
      frame.snapshotPublishedAt(now: now, nowMonoNs: 1_010_000_000))
    let decision = TerminalRenderGate.outputSettleDecision(
      terminalDirty: true,
      sessionId: "session-1",
      lastDirtyAt: dirtyAt,
      now: now,
      hold: nil,
      quiet: 0.012,
      maxHold: 0.025)
    XCTAssertTrue(decision.shouldDefer)
    XCTAssertEqual(decision.wakeAfter ?? 0, 0.002, accuracy: 0.000_001)

    let quietEnoughDirtyAt = try XCTUnwrap(
      frame.snapshotPublishedAt(now: now, nowMonoNs: 1_013_000_000))
    let quietEnough = TerminalRenderGate.outputSettleDecision(
      terminalDirty: true,
      sessionId: "session-1",
      lastDirtyAt: quietEnoughDirtyAt,
      now: now,
      hold: nil,
      quiet: 0.012,
      maxHold: 0.025)
    XCTAssertFalse(quietEnough.shouldDefer)
  }

  func testDirtySynchronizedOutputDoesNotAdvanceRenderedFrame() throws {
    let oldRenderer = getenv("LABAN_RENDERER").map { String(cString: $0) }
    setenv("LABAN_RENDERER", "software", 1)
    defer {
      if let oldRenderer {
        setenv("LABAN_RENDERER", oldRenderer, 1)
      } else {
        unsetenv("LABAN_RENDERER")
      }
    }

    let rows: Int32 = 4
    let cols: Int32 = 40
    var size = LabanTerminalSize()
    size.rows = rows
    size.cols = cols
    let model = try AppModel(initialSize: size) { try Session.fixture(size: $0) }

    let fontAtlas = FontAtlas(pointSize: 14)
    let sidebarFontAtlas = FontAtlas(pointSize: 11)
    let cellSize = fontAtlas.cellSize
    let cellWidth = Int(cellSize.width)
    let cellHeight = Int(cellSize.height)
    let insets = TerminalBitmapView.contentInsets
    let viewWidth =
      SidebarLayout.defaultWidth + insets.left + CGFloat(cols) * CGFloat(cellWidth) + insets.right
    let viewHeight = insets.top + CGFloat(rows) * CGFloat(cellHeight) + insets.bottom

    let view = TerminalBitmapView(
      model: model,
      fontAtlas: fontAtlas,
      sidebarFontAtlas: sidebarFontAtlas,
      cellWidth: cellWidth,
      cellHeight: cellHeight
    )
    view.frame = NSRect(x: 0, y: 0, width: viewWidth, height: viewHeight)

    view.advanceFrame()
    let baselineFrame = view.renderedFrameCountForTests
    XCTAssertEqual(baselineFrame, 1)

    guard let activeTab = model.activeTab,
      let session = model.session(forTab: activeTab.id)
    else {
      XCTFail("model must have an active fixture session")
      return
    }

    session.write(Array("\u{1B}[?2026h\u{1B}[H\u{1B}[Kin-progress redraw".utf8))
    XCTAssertTrue(session.synchronizedOutputActive)

    view.advanceFrame()
    XCTAssertEqual(
      view.renderedFrameCountForTests,
      baselineFrame,
      "dirty synchronized output must keep presenting the last completed frame")

    view.synchronizedOutputHoldForTests = TerminalRenderGate.SynchronizedOutputHold(
      sessionId: session.id,
      startedAt: Date(timeIntervalSinceNow: -2)
    )

    view.advanceFrame()
    XCTAssertEqual(
      view.renderedFrameCountForTests,
      baselineFrame + 1,
      "stuck synchronized output must render once the watchdog expires")
    XCTAssertFalse(session.synchronizedOutputActive)

    session.write(Array("\u{1B}[?2026h\u{1B}[H\u{1B}[Ksecond synced redraw".utf8))
    XCTAssertTrue(session.synchronizedOutputActive)

    view.advanceFrame()
    XCTAssertEqual(
      view.renderedFrameCountForTests,
      baselineFrame + 1,
      "a later synchronized output window must be gated again")

    session.write(Array("\u{1B}[?2026l".utf8))
    XCTAssertFalse(session.synchronizedOutputActive)

    view.advanceFrame()
    XCTAssertEqual(
      view.renderedFrameCountForTests,
      baselineFrame + 2,
      "completed synchronized output must render once the mode exits")
  }
}
