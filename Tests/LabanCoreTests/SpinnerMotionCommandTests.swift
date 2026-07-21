import CoreGraphics
import LabanRenderer
import XCTest

@testable import LabanCore

final class SpinnerMotionCommandTests: XCTestCase {
  private func remoteSnapshot(cells: [LabandSnapshotCell]) -> LabandSnapshotResponse {
    LabandSnapshotResponse(
      logicalSessionId: "",
      incarnationId: "",
      rows: 1,
      cols: cells.count,
      cursorRow: 0,
      cursorCol: cells.count,
      cursorVisible: false,
      title: "",
      lifecycleState: .running,
      exitStatus: nil,
      dirty: true,
      visibleText: cells.map(\.text).joined(),
      cells: cells,
      defaultBackgroundRGBA: 0x0000_00FF)
  }

  func testRemoteForegroundTransitionSplitsRun() {
    let cells = [
      LabandSnapshotCell(
        row: 0, col: 0, text: "A", flags: 0,
        foregroundRGBA: 0xFF00_00FF, backgroundRGBA: 0x0000_00FF),
      LabandSnapshotCell(
        row: 0, col: 1, text: "B", flags: 0,
        foregroundRGBA: 0xFF00_00FF, backgroundRGBA: 0x0000_00FF),
    ]
    let snapshot = remoteSnapshot(cells: cells)
    let transition = GlyphForegroundTransition(
      startLinearRGBA: SIMD4<Float>(0, 0, 1, 1),
      startTimestampSeconds: 0,
      durationSeconds: 0.25)
    let transitions = [SpinnerMotionCellKey(row: 0, col: 0): transition]
    let cmds = FrameProducer(cellWidth: 8, cellHeight: 16).commands(
      from: snapshot,
      foregroundTransitions: transitions)
    let runs = cmds.compactMap {
      command -> (text: String, transition: GlyphForegroundTransition?)? in
      if case .glyphRun(_, let text, _, _, _, _, _, _, _, _, _, let t, _) = command {
        return (text, t)
      }
      return nil
    }
    XCTAssertEqual(runs.map(\.text), ["A", "B"])
    XCTAssertNotNil(runs[0].transition)
    XCTAssertNil(runs[1].transition)
  }

  func testRemoteFaintForegroundMatchesLocalResolution() {
    // Faint attribute halves the foreground against the background.
    let cell = LabandSnapshotCell(
      row: 0,
      col: 0,
      text: "◆",
      flags: TextAttributes.faint.rawValue,
      foregroundRGBA: 0xFF00_00FF,
      backgroundRGBA: 0x0000_00FF)
    let states = FrameProducer(cellWidth: 8, cellHeight: 16).spinnerCellStates(
      from: remoteSnapshot(cells: [cell]))
    let state = states[SpinnerMotionCellKey(row: 0, col: 0)]!
    // 50% foreground blended toward black: ~0x800000FF.
    XCTAssertEqual(state.foreground, 0x8000_00FF)
  }
}
