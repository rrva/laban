import AppKit
import CoreGraphics
import LabanCore
import LabanRenderer
import LabanTerminalCore
import XCTest

@testable import LabanApp

/// Hunts the "labpty drift" stall: the view believes it is pinned to the live
/// bottom (`appliedScrollRows == 0`) while libghostty's viewport has silently
/// left follow-output mode. Streamed output then lands below the viewport,
/// no viewport row dirties, `advanceFrame` early-returns forever, and the
/// screen freezes until a scroll or keystroke re-pins — the "claude code
/// progress bar stalls until I scroll" report.
///
/// Each case runs one candidate inducer (escape traffic a TUI like Claude
/// Code actually emits, or scroll mechanics) from a bottom-pinned state, then
/// probes the invariant: streaming more output must keep the viewport on the
/// live bottom.
final class ViewportFollowDriftTests: XCTestCase {

  private func withSoftwareRenderer(_ body: () throws -> Void) rethrows {
    let old = getenv("LABAN_RENDERER").map { String(cString: $0) }
    setenv("LABAN_RENDERER", "software", 1)
    defer {
      if let old { setenv("LABAN_RENDERER", old, 1) } else { unsetenv("LABAN_RENDERER") }
    }
    try body()
  }

  private struct Harness {
    let view: TerminalBitmapView
    let session: Session
    let cellHeight: Int
    var nextLine = 0

    mutating func stream(_ count: Int) {
      var text = ""
      for _ in 0..<count {
        text += "line \(nextLine)\r\n"
        nextLine += 1
      }
      session.write(Array(text.utf8))
      view.advanceFrame()
    }

    func write(_ raw: String) {
      session.write(Array(raw.utf8))
      view.advanceFrame()
    }

    func linesBack() throws -> Int {
      let vs = try XCTUnwrap(session.viewportState())
      return max(0, max(0, vs.totalRows - vs.viewportRows) - vs.viewportOffset)
    }

    func wheel(rowsUp: Int) -> TestScrollWheelEvent {
      TestScrollWheelEvent(
        locationInWindow: CGPoint(x: SidebarLayout.defaultWidth + 50, y: 50),
        deltaY: 0,
        scrollingDeltaY: CGFloat(rowsUp * cellHeight),
        hasPreciseScrollingDeltas: true
      )
    }
  }

  private func makeHarness(rows: Int16 = 6, cols: Int16 = 40) throws -> Harness {
    var size = LabanTerminalSize()
    size.rows = Int32(rows)
    size.cols = Int32(cols)
    let model = try AppModel(initialSize: size) { try Session.fixture(size: $0) }
    let fontAtlas = FontAtlas(pointSize: 14)
    let sidebarFontAtlas = FontAtlas(pointSize: 11)
    let cellSize = fontAtlas.cellSize
    let insets = TerminalBitmapView.contentInsets
    let viewWidth =
      SidebarLayout.defaultWidth + insets.left + CGFloat(cols) * cellSize.width + insets.right
    let viewHeight = insets.top + CGFloat(rows) * cellSize.height + insets.bottom
    let view = TerminalBitmapView(
      model: model,
      fontAtlas: fontAtlas,
      sidebarFontAtlas: sidebarFontAtlas,
      cellWidth: Int(cellSize.width),
      cellHeight: Int(cellSize.height)
    )
    view.frame = NSRect(x: 0, y: 0, width: viewWidth, height: viewHeight)
    let activeTab = try XCTUnwrap(model.activeTab)
    let session = try XCTUnwrap(model.session(forTab: activeTab.id))
    return Harness(view: view, session: session, cellHeight: Int(cellSize.height))
  }

  /// Streams after the inducer and asserts the viewport followed. The probe
  /// streams twice: drift can hide for one burst if the inducer left the
  /// viewport positionally at the bottom but anchored to a scrollback pin.
  private func assertFollowsLiveBottom(
    _ h: inout Harness, _ inducer: String, file: StaticString = #filePath, line: UInt = #line
  ) throws {
    h.stream(3)
    XCTAssertEqual(
      try h.linesBack(), 0,
      "\(inducer): first streamed burst left the viewport behind the live bottom",
      file: file, line: line)
    h.stream(10)
    XCTAssertEqual(
      try h.linesBack(), 0,
      "\(inducer): viewport stopped following streamed output",
      file: file, line: line)
  }

  // MARK: - Inducers while sitting at the bottom (no user interaction)

  func testAltScreenRoundTripKeepsFollow() throws {
    try withSoftwareRenderer {
      var h = try makeHarness()
      h.stream(120)
      XCTAssertEqual(try h.linesBack(), 0)
      h.write("\u{1b}[?1049h\u{1b}[2J\u{1b}[Halt screen body\u{1b}[?1049l")
      try assertFollowsLiveBottom(&h, "alt-screen round trip")
    }
  }

  func testScrollbackEraseKeepsFollow() throws {
    try withSoftwareRenderer {
      var h = try makeHarness()
      h.stream(120)
      XCTAssertEqual(try h.linesBack(), 0)
      // Claude Code /clear: clear screen, erase scrollback, home.
      h.write("\u{1b}[2J\u{1b}[3J\u{1b}[H")
      try assertFollowsLiveBottom(&h, "ED2+ED3+home")
    }
  }

  func testScrollRegionRedrawKeepsFollow() throws {
    try withSoftwareRenderer {
      var h = try makeHarness()
      h.stream(120)
      XCTAssertEqual(try h.linesBack(), 0)
      // Pinned progress bar pattern: scroll region above a status row,
      // stream into the region, redraw the status row, reset the region.
      h.write("\u{1b}[1;5r\u{1b}[5;1H")
      h.stream(20)
      h.write("\u{1b}[6;1H\u{1b}[2Kprogress 42%\u{1b}[r\u{1b}[6;1H")
      try assertFollowsLiveBottom(&h, "DECSTBM region redraw")
    }
  }

  func testSynchronizedOutputRedrawKeepsFollow() throws {
    try withSoftwareRenderer {
      var h = try makeHarness()
      h.stream(120)
      XCTAssertEqual(try h.linesBack(), 0)
      for _ in 0..<5 {
        h.write("\u{1b}[?2026h\r\u{1b}[2Kspinner ⠋ working...\u{1b}[?2026l")
        h.stream(2)
      }
      try assertFollowsLiveBottom(&h, "synchronized-output redraw cycles")
    }
  }

  func testCursorUpRedrawKeepsFollow() throws {
    try withSoftwareRenderer {
      var h = try makeHarness()
      h.stream(120)
      XCTAssertEqual(try h.linesBack(), 0)
      // Multi-line progress redraw: cursor up over its own rows, erase, rewrite.
      for i in 0..<10 {
        h.write("\u{1b}[2A\r\u{1b}[2Kprogress \(i)\r\n\u{1b}[2Ktokens \(i * 37)\r\n")
        h.stream(1)
      }
      try assertFollowsLiveBottom(&h, "cursor-up redraw loop")
    }
  }

  // MARK: - Inducers around user scrollback

  func testAltScreenRoundTripWhileScrolledBackThenReturn() throws {
    try withSoftwareRenderer {
      var h = try makeHarness()
      h.stream(120)
      h.view.scrollWheel(with: h.wheel(rowsUp: 5))
      h.view.advanceFrame()
      XCTAssertGreaterThan(try h.linesBack(), 0)
      h.write("\u{1b}[?1049h\u{1b}[2J\u{1b}[Hpicker\u{1b}[?1049l")
      h.view.scrollWheel(with: h.wheel(rowsUp: -8))
      h.view.advanceFrame()
      try assertFollowsLiveBottom(&h, "alt-screen during scrollback + return")
    }
  }

  func testScrollbackEraseWhileScrolledBackThenReturn() throws {
    try withSoftwareRenderer {
      var h = try makeHarness()
      h.stream(120)
      h.view.scrollWheel(with: h.wheel(rowsUp: 5))
      h.view.advanceFrame()
      XCTAssertGreaterThan(try h.linesBack(), 0)
      h.write("\u{1b}[2J\u{1b}[3J\u{1b}[H")
      h.view.scrollWheel(with: h.wheel(rowsUp: -8))
      h.view.advanceFrame()
      try assertFollowsLiveBottom(&h, "ED3 during scrollback + return")
    }
  }

  /// Fractional trackpad deltas with momentum phases while output streams —
  /// the residual-px accountant and clamp-reset interplay is the least-covered
  /// scroll path. The user ends their gesture back at the bottom; follow must
  /// re-engage no matter how the fractions landed.
  func testFractionalMomentumScrollRaceThenReturn() throws {
    try withSoftwareRenderer {
      var h = try makeHarness()
      h.stream(120)
      XCTAssertEqual(try h.linesBack(), 0)
      let px = CGFloat(h.cellHeight)
      func wheelPx(_ deltaPx: CGFloat, phase: NSEvent.Phase, momentum: NSEvent.Phase = []) {
        h.view.scrollWheel(
          with: TestScrollWheelEvent(
            locationInWindow: CGPoint(x: SidebarLayout.defaultWidth + 50, y: 50),
            deltaY: 0,
            scrollingDeltaY: deltaPx,
            hasPreciseScrollingDeltas: true,
            phase: phase,
            momentumPhase: momentum))
        h.view.advanceFrame()
      }
      // Gesture up in uneven fractions while the child streams.
      wheelPx(0.6 * px, phase: .began)
      h.stream(1)
      wheelPx(1.7 * px, phase: .changed)
      h.stream(1)
      wheelPx(0.9 * px, phase: .changed)
      wheelPx(0, phase: .ended)
      // Momentum back down in uneven fractions, overshooting the bottom.
      wheelPx(-1.3 * px, phase: [], momentum: .began)
      h.stream(1)
      wheelPx(-1.4 * px, phase: [], momentum: .changed)
      wheelPx(-2.5 * px, phase: [], momentum: .changed)
      wheelPx(0, phase: [], momentum: .ended)
      h.view.advanceFrame()
      try assertFollowsLiveBottom(&h, "fractional momentum gesture")
    }
  }
}
