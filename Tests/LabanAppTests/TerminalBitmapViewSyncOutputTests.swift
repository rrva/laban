import AppKit
import Darwin
import LabanCore
import LabanRenderer
import LabanTerminalCore
import XCTest

@testable import LabanApp

final class TerminalBitmapViewSyncOutputTests: XCTestCase {

  func testFailedRPCConfirmationHonorsRetryBackoffAfterQuietWindow() {
    let observedAt = Date(timeIntervalSinceReferenceDate: 1_000)
    let retryNotBefore = observedAt.addingTimeInterval(0.2)

    XCTAssertFalse(
      TerminalBitmapView.remoteHoverPreviewConfirmationReady(
        observedAt: observedAt,
        retryNotBefore: retryNotBefore,
        now: observedAt.addingTimeInterval(0.1)),
      "an already-quiet candidate must not bypass backoff after confirmation failed")
    XCTAssertTrue(
      TerminalBitmapView.remoteHoverPreviewConfirmationReady(
        observedAt: observedAt,
        retryNotBefore: retryNotBefore,
        now: retryNotBefore))
    XCTAssertTrue(
      TerminalBitmapView.remoteHoverPreviewConfirmationReady(
        observedAt: observedAt,
        retryNotBefore: nil,
        now: observedAt.addingTimeInterval(
          TerminalRenderGate.outputSettleQuietSeconds + 0.001)),
      "the first confirmation may run as soon as its quiet window opens")
  }

  func testRemotePreviewRetryWakeRequiresVisibleWindowAndEligibleTarget() {
    XCTAssertTrue(
      TerminalBitmapView.hoverPreviewSnapshotRetryShouldWake(
        windowVisibleToUser: true,
        retryTabId: "preview",
        eligiblePreviewTabId: "preview"))
    XCTAssertFalse(
      TerminalBitmapView.hoverPreviewSnapshotRetryShouldWake(
        windowVisibleToUser: false,
        retryTabId: "preview",
        eligiblePreviewTabId: "preview"),
      "occluded, minimized, or inactive windows must not poll preview snapshots")
    XCTAssertFalse(
      TerminalBitmapView.hoverPreviewSnapshotRetryShouldWake(
        windowVisibleToUser: true,
        retryTabId: "preview",
        eligiblePreviewTabId: nil))
  }

  func testRemotePreviewSnapshotAttemptRequiresVisibleWindow() {
    XCTAssertFalse(
      TerminalBitmapView.remoteHoverPreviewSnapshotShouldAttempt(
        windowVisibleToUser: false,
        retryAllowed: true),
      "non-timer wakes must not poll optional preview transport while hidden")
    XCTAssertTrue(
      TerminalBitmapView.remoteHoverPreviewSnapshotShouldAttempt(
        windowVisibleToUser: true,
        retryAllowed: true))
    XCTAssertFalse(
      TerminalBitmapView.remoteHoverPreviewSnapshotShouldAttempt(
        windowVisibleToUser: true,
        retryAllowed: false))
  }

  func testAcknowledgedFailedLocalPreviewDoesNotRearmAsNewEveryFrame() {
    XCTAssertTrue(
      TerminalBitmapView.localHoverPreviewIsNew(
        targetTabId: "preview",
        acknowledgedTabId: nil))
    XCTAssertFalse(
      TerminalBitmapView.localHoverPreviewIsNew(
        targetTabId: "preview",
        acknowledgedTabId: "preview"),
      "an attempted preview is acknowledged separately from whether panel commands rendered")
    XCTAssertFalse(
      TerminalBitmapView.localHoverPreviewIsNew(
        targetTabId: nil,
        acknowledgedTabId: nil))
  }

  func testRecoveredHoverPreviewForcesFullDamageWhenPanelFirstAppears() {
    let partial = RenderDamage.partial(yRanges: [DirtyYRange(y: 20, height: 10)])

    XCTAssertEqual(
      TerminalBitmapView.damageForHoverPreviewTransition(
        proposedDamage: partial,
        renderedTabId: "preview",
        previouslyRenderedTabId: nil),
      .full,
      "a panel recovering after an absent snapshot must not inherit terminal-row damage")
    XCTAssertEqual(
      TerminalBitmapView.damageForHoverPreviewTransition(
        proposedDamage: partial,
        renderedTabId: "preview",
        previouslyRenderedTabId: "preview"),
      partial,
      "an unchanged panel keeps the ordinary damage policy")
    XCTAssertEqual(
      TerminalBitmapView.damageForHoverPreviewTransition(
        proposedDamage: partial,
        renderedTabId: nil,
        previouslyRenderedTabId: nil),
      partial,
      "a failed retry with no panel must not start a full-damage loop")
  }

  func testRemoteSynchronizedOutputWatchdogBypassSuppressesStuckMode() {
    XCTAssertTrue(
      TerminalBitmapView.effectiveRemoteSynchronizedOutput(
        reportedActive: true,
        watchdogBypassed: false))
    XCTAssertFalse(
      TerminalBitmapView.effectiveRemoteSynchronizedOutput(
        reportedActive: true,
        watchdogBypassed: true),
      "a timed-out daemon flag must not begin another one-second hold")
    XCTAssertFalse(
      TerminalBitmapView.effectiveRemoteSynchronizedOutput(
        reportedActive: false,
        watchdogBypassed: false))
  }

  func testPreviewOutputSettleRemainsEligibleDuringActivePaneMotion() {
    let scrolling = TerminalBitmapView.outputSettleEligibility(
      tabChanged: false,
      scrollAnimating: true,
      renderingResizeFrame: false,
      hasVisibleHoverPreview: true)
    XCTAssertFalse(scrolling.activePane)
    XCTAssertTrue(scrolling.hoverPreview)

    let resizing = TerminalBitmapView.outputSettleEligibility(
      tabChanged: false,
      scrollAnimating: false,
      renderingResizeFrame: true,
      hasVisibleHoverPreview: true)
    XCTAssertFalse(resizing.activePane)
    XCTAssertTrue(resizing.hoverPreview)
  }

  func testLocalPreviewSnapshotRetryRequiresDueVisibleMatchingTarget() {
    let now = Date(timeIntervalSinceReferenceDate: 1_000)
    let notBefore = now.addingTimeInterval(0.1)

    XCTAssertFalse(
      TerminalBitmapView.localHoverPreviewSnapshotRetryIsDue(
        windowVisibleToUser: true,
        retryTabId: "preview",
        eligiblePreviewTabId: "preview",
        retryNotBefore: notBefore,
        now: now))
    XCTAssertTrue(
      TerminalBitmapView.localHoverPreviewSnapshotRetryIsDue(
        windowVisibleToUser: true,
        retryTabId: "preview",
        eligiblePreviewTabId: "preview",
        retryNotBefore: notBefore,
        now: notBefore))
    XCTAssertFalse(
      TerminalBitmapView.localHoverPreviewSnapshotRetryIsDue(
        windowVisibleToUser: false,
        retryTabId: "preview",
        eligiblePreviewTabId: "preview",
        retryNotBefore: notBefore,
        now: notBefore))
    XCTAssertFalse(
      TerminalBitmapView.localHoverPreviewSnapshotRetryIsDue(
        windowVisibleToUser: true,
        retryTabId: "preview",
        eligiblePreviewTabId: "other",
        retryNotBefore: notBefore,
        now: notBefore))
  }

  func testNewLocalPreviewEvaluatesAcknowledgedOutputCoherence() {
    XCTAssertTrue(
      TerminalBitmapView.localHoverPreviewNeedsCoherence(
        isNewPreview: true,
        sessionDirty: false,
        synchronizedOutputActive: true,
        lastOutputAt: nil),
      "initial hover during synchronized output must not sample an intermediate snapshot")
    XCTAssertTrue(
      TerminalBitmapView.localHoverPreviewNeedsCoherence(
        isNewPreview: true,
        sessionDirty: false,
        synchronizedOutputActive: false,
        lastOutputAt: Date(timeIntervalSinceReferenceDate: 1_000)),
      "already-acknowledged background output still needs the settle timestamp evaluated")
    XCTAssertFalse(
      TerminalBitmapView.localHoverPreviewNeedsCoherence(
        isNewPreview: false,
        sessionDirty: false,
        synchronizedOutputActive: false,
        lastOutputAt: Date(timeIntervalSinceReferenceDate: 1_000)),
      "an unchanged, already-rendered preview must not become dirty on every frame")
  }

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
        hold: TerminalRenderGate.SynchronizedOutputHold(sessionId: "session-1", startedAt: start),
        wakeAfter: TerminalRenderGate.synchronizedOutputMaxHoldSeconds))

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

  func testSynchronizedOutputDeferReportsBoundedWakeAfter() throws {
    let start = Date(timeIntervalSinceReferenceDate: 1_000)
    let timeout = TerminalRenderGate.synchronizedOutputMaxHoldSeconds

    // A deferred synchronized-output frame must carry its own re-wake delay so a
    // parked display link still reaches the watchdog; nil here is the stranded-
    // frame bug ("progress bar frozen until I scroll").
    let fresh = TerminalRenderGate.synchronizedOutputDecision(
      terminalDirty: true,
      synchronizedOutputActive: true,
      sessionId: "session-1",
      now: start,
      hold: nil)
    XCTAssertTrue(fresh.shouldDefer)
    let freshWake = try XCTUnwrap(
      fresh.wakeAfter, "a deferred synchronized-output frame must schedule its own re-wake")
    XCTAssertEqual(freshWake, timeout, accuracy: 0.000_001)
    XCTAssertGreaterThan(freshWake, 0)

    // Closer to the deadline the re-wake shrinks to the remaining window, so the
    // reset lands right at the watchdog rather than a fixed interval later.
    let near = TerminalRenderGate.synchronizedOutputDecision(
      terminalDirty: true,
      synchronizedOutputActive: true,
      sessionId: "session-1",
      now: start.addingTimeInterval(0.95),
      hold: fresh.hold)
    XCTAssertTrue(near.shouldDefer)
    let nearWake = try XCTUnwrap(near.wakeAfter)
    XCTAssertEqual(nearWake, timeout - 0.95, accuracy: 0.000_001)

    // Non-deferring outcomes schedule no re-wake.
    let inactive = TerminalRenderGate.synchronizedOutputDecision(
      terminalDirty: true,
      synchronizedOutputActive: false,
      sessionId: "session-1",
      now: start,
      hold: nil)
    XCTAssertFalse(inactive.shouldDefer)
    XCTAssertNil(inactive.wakeAfter)

    let timedOut = TerminalRenderGate.synchronizedOutputDecision(
      terminalDirty: true,
      synchronizedOutputActive: true,
      sessionId: "session-1",
      now: start.addingTimeInterval(timeout + 0.001),
      hold: fresh.hold)
    XCTAssertTrue(timedOut.shouldResetMode)
    XCTAssertNil(timedOut.wakeAfter)
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
