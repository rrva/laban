import CoreGraphics
import LabanRenderer
import XCTest

@testable import LabanCore

/// The remote `FrameProducer.commands(from: LabandSnapshotResponse, ...)`
/// overload must honor the daemon-supplied default background color so a
/// transparent first cell never leaks through as a black band between the
/// sidebar and the terminal area. This pins the contract that supersedes
/// the brittle `cells.first?.backgroundRGBA ?? Theme.current.bg0` fallback.
final class FrameProducerRemoteDefaultBackgroundTests: XCTestCase {

  private let cellW = 8
  private let cellH = 16
  private let viewportW = 80
  private let viewportH = 16

  private func snapshot(
    cells: [LabandSnapshotCell],
    defaultBackgroundRGBA: UInt32? = nil
  ) -> LabandSnapshotResponse {
    LabandSnapshotResponse(
      logicalSessionId: "test",
      incarnationId: "1",
      rows: 1,
      cols: 1,
      cursorRow: 0,
      cursorCol: 0,
      cursorVisible: false,
      title: "",
      lifecycleState: .running,
      exitStatus: nil,
      dirty: false,
      visibleText: "",
      cells: cells,
      defaultBackgroundRGBA: defaultBackgroundRGBA
    )
  }

  private func firstTerminalRectColor(_ cmds: [FrameCommand]) -> UInt32? {
    for cmd in cmds {
      if case .rect(_, let color, let src, _) = cmd, src == .terminal {
        return color
      }
    }
    return nil
  }

  func testHonorsDaemonSuppliedDefaultBackground() {
    // The daemon reports a real terminal-background color; the first cell
    // happens to be unstyled (background == 0). Without the fix, the
    // terminal-area rect would paint 0 (transparent black). With the fix,
    // the daemon's value wins.
    let snapshot = snapshot(
      cells: [
        LabandSnapshotCell(
          row: 0, col: 0, text: "", flags: 0,
          foregroundRGBA: 0xFFFF_FFFF, backgroundRGBA: 0)
      ],
      defaultBackgroundRGBA: 0x12_34_56_FF)

    let cmds = FrameProducer(cellWidth: cellW, cellHeight: cellH)
      .commands(from: snapshot)

    XCTAssertEqual(
      firstTerminalRectColor(cmds), 0x12_34_56_FF,
      "the terminal-area rect must use the daemon-supplied defaultBackgroundRGBA")
  }

  func testFallsBackToThemeWhenDefaultBackgroundMissing() {
    // Pre-2026-05 daemons / ring snapshots leave the field nil. Code must
    // not fall through to `cells.first?.backgroundRGBA` (which would be 0
    // here) — it must reach the theme default.
    let snapshot = snapshot(
      cells: [
        LabandSnapshotCell(
          row: 0, col: 0, text: "", flags: 0,
          foregroundRGBA: 0xFFFF_FFFF, backgroundRGBA: 0)
      ],
      defaultBackgroundRGBA: nil)

    let cmds = FrameProducer(cellWidth: cellW, cellHeight: cellH)
      .commands(from: snapshot)

    XCTAssertEqual(
      firstTerminalRectColor(cmds), Theme.current.bg0,
      "missing defaultBackgroundRGBA must fall back to the theme, not to 0")
  }

  func testTreatsExplicitZeroAsMissing() {
    // If a future daemon explicitly emits 0 (e.g., transparent), the
    // renderer must still avoid painting a transparent rect because the
    // underlying layer-backed view is not guaranteed to be theme-colored.
    let snapshot = snapshot(
      cells: [
        LabandSnapshotCell(
          row: 0, col: 0, text: "", flags: 0,
          foregroundRGBA: 0xFFFF_FFFF, backgroundRGBA: 0xAABB_CCFF)
      ],
      defaultBackgroundRGBA: 0)

    let cmds = FrameProducer(cellWidth: cellW, cellHeight: cellH)
      .commands(from: snapshot)

    XCTAssertEqual(
      firstTerminalRectColor(cmds), Theme.current.bg0,
      "zero defaultBackgroundRGBA must be treated as 'unknown', not painted")
  }
}
