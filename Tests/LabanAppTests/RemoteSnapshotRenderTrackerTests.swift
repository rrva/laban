import LabanCore
import XCTest

@testable import LabanApp

final class RemoteSnapshotRenderTrackerTests: XCTestCase {
  private func snapshot(
    text: String,
    dirty: Bool,
    synchronizedOutput: Bool? = false,
    incarnationId: String = "incarnation-1"
  ) -> LabandSnapshotResponse {
    LabandSnapshotResponse(
      logicalSessionId: "session-1",
      incarnationId: incarnationId,
      rows: 1,
      cols: 1,
      cursorRow: 0,
      cursorCol: 0,
      cursorVisible: false,
      title: "",
      lifecycleState: .running,
      exitStatus: nil,
      dirty: dirty,
      visibleText: text,
      cells: [
        LabandSnapshotCell(
          row: 0,
          col: 0,
          text: text,
          flags: 0,
          foregroundRGBA: 0xFF_FF_FF_FF,
          backgroundRGBA: 0x00_00_00_FF)
      ],
      defaultBackgroundRGBA: 0x00_00_00_FF,
      synchronizedOutput: synchronizedOutput)
  }

  private func frame(text: String, dirty: Bool) -> LabandSnapshotFrame {
    LabandSnapshotFrame(
      generation: nil,
      snapshot: snapshot(text: text, dirty: dirty))
  }

  func testGenerationIsDirtyOnlyUntilRendered() {
    var tracker = RemoteSnapshotRenderTracker()
    let tabId = "tab-1"

    XCTAssertTrue(
      tracker.terminalDirty(tabId: tabId, generation: 7, fallbackDirty: true))

    tracker.markRendered(tabId: tabId, generation: 7)

    XCTAssertFalse(
      tracker.terminalDirty(tabId: tabId, generation: 7, fallbackDirty: true))
    XCTAssertTrue(
      tracker.terminalDirty(tabId: tabId, generation: 8, fallbackDirty: false))
  }

  func testNilGenerationUsesFallbackDirtyFlag() {
    var tracker = RemoteSnapshotRenderTracker()
    let tabId = "tab-1"
    tracker.markRendered(tabId: tabId, generation: 7)

    XCTAssertTrue(
      tracker.terminalDirty(tabId: tabId, generation: nil, fallbackDirty: true))
    XCTAssertFalse(
      tracker.terminalDirty(tabId: tabId, generation: nil, fallbackDirty: false))
  }

  func testMissingPreviewRingComparesRenderedContentInsteadOfDaemonDirtyBit() {
    XCTAssertTrue(
      TerminalBitmapView.remoteHoverPreviewContentMatches(
        snapshot(text: "same", dirty: true),
        snapshot(text: "same", dirty: false)),
      "markRendered changing only the daemon dirty bit must not invalidate identical pixels")
    XCTAssertFalse(
      TerminalBitmapView.remoteHoverPreviewContentMatches(
        snapshot(text: "old", dirty: true),
        snapshot(text: "new", dirty: false)),
      "a newer clean RPC snapshot must replace stale cached preview pixels")
    XCTAssertFalse(
      TerminalBitmapView.remoteHoverPreviewContentMatches(
        snapshot(text: "same", dirty: false, synchronizedOutput: false),
        snapshot(text: "same", dirty: false, synchronizedOutput: true)),
      "synchronized-output state participates in preview coherence even before pixels change")
    XCTAssertFalse(
      TerminalBitmapView.remoteHoverPreviewContentMatches(
        snapshot(text: "same", dirty: false),
        snapshot(text: "same", dirty: false, incarnationId: "incarnation-2")),
      "a restarted daemon session must not alias the previous incarnation's cache")
  }

  func testMatchingRPCFallbackKeepsFreshAcknowledgementMetadata() {
    let cached = frame(text: "same", dirty: true)
    let fetched = frame(text: "same", dirty: false)

    let resolution = TerminalBitmapView.resolveRemoteHoverPreviewFallback(
      cachedFrame: cached,
      fetchedFrame: fetched)

    XCTAssertFalse(resolution.contentChanged)
    XCTAssertFalse(
      resolution.frame.snapshot.dirty,
      "matching pixels must still adopt the daemon's freshly cleared dirty bit")
  }

  func testFallbackConfirmationBackoffKeepsOnlyCompletedPreviewOnGlass() {
    let cached = frame(text: "completed", dirty: false)
    let unconfirmed = frame(text: "candidate", dirty: true)

    let resolution = TerminalBitmapView.resolveRemoteHoverPreviewBackoff(
      cachedFrame: cached,
      unconfirmedFrame: unconfirmed)

    XCTAssertEqual(resolution.frame?.snapshot.visibleText, "completed")
    XCTAssertFalse(
      resolution.terminalDirty,
      "retry backoff must not feed the unconfirmed candidate into the settle/render path")
  }

  func testPreviewRingRefreshUsesPreviewCacheIdentityNotActiveRenderTrackerState() {
    let cached = LabandSnapshotFrame(
      generation: 7,
      snapshot: snapshot(text: "cached", dirty: false))

    XCTAssertFalse(
      TerminalBitmapView.remoteHoverPreviewRingNeedsRefresh(
        cachedFrame: cached,
        incarnationId: "incarnation-1",
        generation: 7))
    XCTAssertTrue(
      TerminalBitmapView.remoteHoverPreviewRingNeedsRefresh(
        cachedFrame: nil,
        incarnationId: "incarnation-1",
        generation: 7),
      "a tab rendered only as the active terminal has no preview cache and must be decoded")
    XCTAssertTrue(
      TerminalBitmapView.remoteHoverPreviewRingNeedsRefresh(
        cachedFrame: cached,
        incarnationId: "incarnation-1",
        generation: 8))
    XCTAssertTrue(
      TerminalBitmapView.remoteHoverPreviewRingNeedsRefresh(
        cachedFrame: cached,
        incarnationId: "incarnation-2",
        generation: 7))
  }

  func testClearForgetsRenderedGeneration() {
    var tracker = RemoteSnapshotRenderTracker()
    let tabId = "tab-1"
    tracker.markRendered(tabId: tabId, generation: 7)

    tracker.clear(tabId: tabId)

    XCTAssertTrue(
      tracker.terminalDirty(tabId: tabId, generation: 7, fallbackDirty: false))
  }

  func testTracksActiveAndPreviewTabGenerationsIndependently() {
    var tracker = RemoteSnapshotRenderTracker()
    tracker.markRendered(tabId: "active", generation: 10)
    tracker.markRendered(tabId: "preview", generation: 4)

    XCTAssertFalse(
      tracker.terminalDirty(tabId: "active", generation: 10, fallbackDirty: false))
    XCTAssertTrue(
      tracker.terminalDirty(tabId: "preview", generation: 5, fallbackDirty: false),
      "background preview output must not be hidden by the active tab's rendered generation")
  }

  func testGenerationReuseAcrossDaemonIncarnationsIsDirty() {
    var tracker = RemoteSnapshotRenderTracker()
    tracker.markRendered(
      tabId: "preview",
      incarnationId: "incarnation-1",
      generation: 4)

    XCTAssertFalse(
      tracker.terminalDirty(
        tabId: "preview",
        incarnationId: "incarnation-1",
        generation: 4,
        fallbackDirty: false))
    XCTAssertTrue(
      tracker.terminalDirty(
        tabId: "preview",
        incarnationId: "incarnation-2",
        generation: 4,
        fallbackDirty: false),
      "a restarted daemon ring may reuse the same generation number for different content")
  }
}
