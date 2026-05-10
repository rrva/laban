import CoreGraphics
import LabanRenderer
import LabanTerminalCore
import XCTest

@testable import LabanCore

final class TerminalSurfaceControllerTests: XCTestCase {
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
