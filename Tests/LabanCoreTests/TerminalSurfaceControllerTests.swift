import CoreGraphics
import Foundation
import LabanRenderer
import LabanTerminalCore
import XCTest

@testable import LabanCore

final class TerminalSurfaceControllerTests: XCTestCase {
  private final class RecordingSurfaceCaptureSink: TerminalSurfaceCaptureSink {
    var events: [CaptureTimelineEvent] = []

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
      nil
    }
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
      if case .rect(_, _, let source) = command { return source == .sidebar }
      return false
    }
    XCTAssertTrue(hasSidebarRect)

    let terminalText = frame.commands.compactMap { command -> String? in
      if case .glyphRun(_, let text, _, _, _, let source, _, _, _) = command,
        source == .terminal
      {
        return text
      }
      return nil
    }.joined()
    XCTAssertTrue(terminalText.contains("hello"), "got terminal text \(terminalText)")
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
    XCTAssertEqual(updatedSecond.titleMetadata.lastOutputAt, now)
    XCTAssertTrue(updatedSecond.titleMetadata.unseenOutput)
    XCTAssertEqual(updatedSecond.titleMetadata.activityState, .unseenOutput)
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
}
