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

  func testRemoteWavePublicationSplitsRunsPerCell() {
    let cells = (0..<4).map { col in
      LabandSnapshotCell(
        row: 0, col: col, text: "A", flags: 0,
        foregroundRGBA: 0x8080_80FF, backgroundRGBA: 0x0000_00FF)
    }
    let snapshot = remoteSnapshot(cells: cells)
    let publication = SpinnerWavePublication(
      wave: SpinnerWaveState(
        row: 0,
        minCol: 1,
        colors: [
          SIMD4<Float>(0.5, 0.5, 0.5, 1),
          SIMD4<Float>(0.6, 0.6, 0.6, 1),
          SIMD4<Float>(0.7, 0.7, 0.7, 1),
        ],
        anchorTimestamp: 10,
        velocityCellsPerSecond: 13.5,
        confidence: 0.95),
      durationSeconds: 0.15)
    let cmds = FrameProducer(cellWidth: 8, cellHeight: 16).commands(
      from: snapshot,
      foregroundWave: publication)

    // The region payload rides command index 1 (right after the canvas
    // rect), before every glyph run that references it.
    guard case .waveRegion(let colors, let anchor, let velocity) = cmds[1] else {
      XCTFail("second command must be the wave region payload, got \(cmds[1])")
      return
    }
    XCTAssertEqual(colors.count, 3)
    XCTAssertEqual(anchor, 10)
    XCTAssertEqual(velocity, 13.5, accuracy: 0.001)

    // Col 0 is outside the field; cols 1...3 each get their own run with
    // ascending cell indexes (per-cell wave metadata forces the split).
    let runs = cmds.compactMap {
      command -> (text: String, wave: GlyphForegroundWave?)? in
      if case .glyphRun(_, let text, _, _, _, _, _, _, _, _, _, _, let wave) = command {
        return (text, wave)
      }
      return nil
    }
    XCTAssertEqual(runs.map { $0.text }, ["A", "A", "A", "A"])
    XCTAssertNil(runs[0].wave)
    for (index, run) in runs.dropFirst().enumerated() {
      XCTAssertEqual(
        run.wave,
        GlyphForegroundWave(
          regionIndex: 0, cellIndexInRegion: UInt32(index), durationSeconds: 0.15))
    }
  }

  func testNoWavePublicationEmitsNoWaveCommands() {
    let cells = [
      LabandSnapshotCell(
        row: 0, col: 0, text: "A", flags: 0,
        foregroundRGBA: 0x8080_80FF, backgroundRGBA: 0x0000_00FF)
    ]
    let cmds = FrameProducer(cellWidth: 8, cellHeight: 16).commands(
      from: remoteSnapshot(cells: cells))
    for command in cmds {
      if case .waveRegion = command {
        XCTFail("no wave publication must produce no waveRegion command")
      }
      if case .glyphRun(_, _, _, _, _, _, _, _, _, _, _, _, let wave) = command {
        XCTAssertNil(wave)
      }
    }
  }
}
