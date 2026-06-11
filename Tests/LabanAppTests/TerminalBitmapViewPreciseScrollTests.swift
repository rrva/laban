import AppKit
import CoreGraphics
import LabanCore
import LabanRenderer
import LabanTerminalCore
import XCTest

@testable import LabanApp

/// Pixel-smooth precise scrolling: trackpad input tracks the finger in
/// fractional rows (integer part on the libghostty viewport, remainder as the
/// sub-cell render offset) and quantizes onto a whole row only at rest.
final class TerminalBitmapViewPreciseScrollTests: XCTestCase {

  override func setUp() {
    super.setUp()
    UserDefaults.standard.removeObject(forKey: ScrollSettings.modeKey)
  }

  override func tearDown() {
    UserDefaults.standard.removeObject(forKey: ScrollSettings.modeKey)
    super.tearDown()
  }

  private func withSoftwareRenderer(_ body: () throws -> Void) rethrows {
    let old = getenv("LABAN_RENDERER").map { String(cString: $0) }
    setenv("LABAN_RENDERER", "software", 1)
    defer {
      if let old { setenv("LABAN_RENDERER", old, 1) } else { unsetenv("LABAN_RENDERER") }
    }
    try body()
  }

  private func makeView(rows: Int16, cols: Int16) throws -> (TerminalBitmapView, AppModel, Int) {
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
    return (view, model, Int(cellSize.height))
  }

  /// A precise (trackpad) wheel event scrolling a fractional number of rows.
  /// Positive = up (toward older history), matching AppKit's sign convention.
  private func preciseWheel(
    rowsUp: Double, cellHeight: Int,
    phase: NSEvent.Phase = [],
    momentumPhase: NSEvent.Phase = []
  ) -> TestScrollWheelEvent {
    TestScrollWheelEvent(
      locationInWindow: CGPoint(x: SidebarLayout.defaultWidth + 50, y: 50),
      deltaY: 0,
      scrollingDeltaY: CGFloat(rowsUp) * CGFloat(cellHeight),
      hasPreciseScrollingDeltas: true,
      phase: phase,
      momentumPhase: momentumPhase
    )
  }

  private func linesBack(_ session: Session) throws -> Int {
    let vs = try XCTUnwrap(session.viewportState())
    return max(0, max(0, vs.totalRows - vs.viewportRows) - vs.viewportOffset)
  }

  /// Run the PD controller until it converges (or the iteration budget runs
  /// out). Wall-clock dt drives the controller, so pace the loop slightly.
  private func settleAnimation(_ view: TerminalBitmapView) {
    for _ in 0..<500 {
      view.advanceFrame()
      let snap = view.debugScrollSnapshot()
      if !snap.animating && snap.displayed == snap.target { return }
      usleep(2000)
    }
  }

  /// The sticky-bottom regression: slow sub-row trackpad scrolling up from
  /// the live bottom must accumulate and leave the bottom. Pre-fix, every
  /// sub-row event rounded the applied rows to 0, which routed through the
  /// active-bottom snap and reset the accumulator — the viewport could never
  /// escape the bottom at low gesture speed.
  func testSlowPreciseScrollLeavesBottom() throws {
    try withSoftwareRenderer {
      let (view, model, cellHeight) = try makeView(rows: 6, cols: 40)
      let activeTab = try XCTUnwrap(model.activeTab)
      let session = try XCTUnwrap(model.session(forTab: activeTab.id))

      session.write(Array((0..<120).map { "line \($0)\r\n" }.joined().utf8))
      view.advanceFrame()
      XCTAssertEqual(try linesBack(session), 0, "starts pinned to the bottom")

      for _ in 0..<10 {
        view.scrollWheel(with: preciseWheel(rowsUp: 0.25, cellHeight: cellHeight))
      }

      let snap = view.debugScrollSnapshot()
      XCTAssertEqual(
        snap.displayed, -2.5, accuracy: 1e-9,
        "ten quarter-row events must accumulate to 2.5 rows of history")
      XCTAssertGreaterThan(
        try linesBack(session), 0,
        "slow sub-row scrolling must actually leave the live bottom")
    }
  }

  /// Fractional 1:1 tracking: displayed/target carry the fraction, the
  /// applied viewport rows stay integer (held below the bottom while the
  /// target is in history), and the difference is the sub-cell render offset.
  func testFractionalTrackingSplitsIntegerAndFraction() throws {
    try withSoftwareRenderer {
      let (view, model, cellHeight) = try makeView(rows: 6, cols: 40)
      let activeTab = try XCTUnwrap(model.activeTab)
      let session = try XCTUnwrap(model.session(forTab: activeTab.id))

      session.write(Array((0..<120).map { "line \($0)\r\n" }.joined().utf8))
      view.advanceFrame()

      view.scrollWheel(with: preciseWheel(rowsUp: 1.5, cellHeight: cellHeight))

      let snap = view.debugScrollSnapshot()
      XCTAssertEqual(snap.displayed, -1.5, accuracy: 1e-9)
      XCTAssertEqual(snap.target, -1.5, accuracy: 1e-9, "gesture tracks 1:1, no controller lag")
      XCTAssertEqual(
        snap.applied,
        TerminalScrollInput.gestureDesiredAppliedRows(displayedRows: -1.5, targetRows: -1.5),
        "applied viewport rows follow the pure helper")
    }
  }

  /// Momentum end settles the resting position onto a whole row via the
  /// existing PD animation: text must sit on exact cell boundaries at rest.
  func testMomentumEndSettlesOnWholeRow() throws {
    try withSoftwareRenderer {
      let (view, model, cellHeight) = try makeView(rows: 6, cols: 40)
      let activeTab = try XCTUnwrap(model.activeTab)
      let session = try XCTUnwrap(model.session(forTab: activeTab.id))

      session.write(Array((0..<120).map { "line \($0)\r\n" }.joined().utf8))
      view.advanceFrame()

      view.scrollWheel(with: preciseWheel(rowsUp: 1.25, cellHeight: cellHeight))
      XCTAssertEqual(view.debugScrollSnapshot().displayed, -1.25, accuracy: 1e-9)

      view.scrollWheel(
        with: preciseWheel(rowsUp: 0, cellHeight: cellHeight, momentumPhase: .ended))
      settleAnimation(view)

      let snap = view.debugScrollSnapshot()
      XCTAssertEqual(snap.displayed, -1.0, "rest position must be a whole row")
      XCTAssertEqual(snap.target, -1.0)
      XCTAssertEqual(snap.displayed, Double(snap.applied), "no sub-cell offset at rest")
    }
  }

  /// A fractional gesture that returns to the bottom must land exactly on the
  /// live bottom and re-engage follow-output, same as the quantized path.
  func testFractionalReturnToBottomReengagesFollow() throws {
    try withSoftwareRenderer {
      let (view, model, cellHeight) = try makeView(rows: 6, cols: 40)
      let activeTab = try XCTUnwrap(model.activeTab)
      let session = try XCTUnwrap(model.session(forTab: activeTab.id))

      func stream(_ range: Range<Int>) {
        session.write(Array(range.map { "line \($0)\r\n" }.joined().utf8))
        view.advanceFrame()
      }

      stream(0..<120)
      view.scrollWheel(with: preciseWheel(rowsUp: 5.5, cellHeight: cellHeight))
      XCTAssertGreaterThan(try linesBack(session), 0, "scrolled back into history")

      view.scrollWheel(with: preciseWheel(rowsUp: -6, cellHeight: cellHeight))
      view.advanceFrame()
      XCTAssertEqual(
        try linesBack(session), 0,
        "a fractional gesture overshooting the bottom clamps to the live bottom")

      stream(120..<160)
      XCTAssertEqual(
        try linesBack(session), 0,
        "after reaching the bottom the viewport must follow new output")
    }
  }

  /// A finger resting mid-gesture (active phase, no events flowing) is
  /// holding the page: the settle timer must NOT fire under it. Pre-fix the
  /// quiescence timer armed on every event regardless of phase, so a slow
  /// or paused gesture settled mid-scroll and the next movement jumped.
  func testRestingFingerMidGestureHoldsFraction() throws {
    try withSoftwareRenderer {
      let (view, model, cellHeight) = try makeView(rows: 6, cols: 40)
      let activeTab = try XCTUnwrap(model.activeTab)
      let session = try XCTUnwrap(model.session(forTab: activeTab.id))

      session.write(Array((0..<120).map { "line \($0)\r\n" }.joined().utf8))
      view.advanceFrame()

      view.scrollWheel(
        with: preciseWheel(rowsUp: 1.4, cellHeight: cellHeight, phase: .changed))
      XCTAssertEqual(view.debugScrollSnapshot().displayed, -1.4, accuracy: 1e-9)

      // Let any (wrongly) armed quiescence timer fire and animate.
      RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))
      for _ in 0..<10 { view.advanceFrame() }

      XCTAssertEqual(
        view.debugScrollSnapshot().displayed, -1.4, accuracy: 1e-9,
        "an active gesture phase must hold the fractional position — no settle under a finger")
    }
  }

  /// A gesture resuming after a settle retarget must continue from the
  /// on-glass position, not the rounded target — otherwise the finger's
  /// first delta is partially eaten by the rounding distance (a jump).
  func testResumedGestureContinuesFromOnGlassPosition() throws {
    try withSoftwareRenderer {
      let (view, model, cellHeight) = try makeView(rows: 6, cols: 40)
      let activeTab = try XCTUnwrap(model.activeTab)
      let session = try XCTUnwrap(model.session(forTab: activeTab.id))

      session.write(Array((0..<120).map { "line \($0)\r\n" }.joined().utf8))
      view.advanceFrame()

      view.scrollWheel(with: preciseWheel(rowsUp: 1.25, cellHeight: cellHeight))
      view.scrollWheel(
        with: preciseWheel(rowsUp: 0, cellHeight: cellHeight, momentumPhase: .ended))
      // Settle retargeted to -1 while displayed sits near -1.25 (the PD may
      // have nudged it slightly toward the target already).

      view.scrollWheel(
        with: preciseWheel(rowsUp: 0.25, cellHeight: cellHeight, phase: .changed))

      // From the rounded target the result would be -1.25 (motion eaten);
      // from the on-glass position it is ≈ -1.5 minus one PD tick.
      XCTAssertLessThan(
        view.debugScrollSnapshot().displayed, -1.4,
        "the resumed delta must move content from the on-glass position, not the settle target")
    }
  }

  /// Phaseless precise streams (synthetic events, some mice) still settle
  /// onto a whole row via the quiescence timer once the stream goes quiet.
  func testPhaselessStreamSettlesAfterQuiescence() throws {
    try withSoftwareRenderer {
      let (view, model, cellHeight) = try makeView(rows: 6, cols: 40)
      let activeTab = try XCTUnwrap(model.activeTab)
      let session = try XCTUnwrap(model.session(forTab: activeTab.id))

      session.write(Array((0..<120).map { "line \($0)\r\n" }.joined().utf8))
      view.advanceFrame()

      view.scrollWheel(with: preciseWheel(rowsUp: 1.4, cellHeight: cellHeight))
      XCTAssertEqual(view.debugScrollSnapshot().displayed, -1.4, accuracy: 1e-9)

      // No phases, no momentum end: only the quiescence timer can settle.
      RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))
      settleAnimation(view)

      let snap = view.debugScrollSnapshot()
      XCTAssertEqual(snap.displayed, -1.0, "quiet phaseless stream must settle on a whole row")
      XCTAssertEqual(snap.displayed, Double(snap.applied), "no sub-cell offset at rest")
    }
  }

  /// Line-quantized mode preserves the original behavior for precise input:
  /// sub-row deltas accumulate in the residual without moving the viewport,
  /// whole rows snap with no fractional state left behind.
  func testLineQuantizedModeKeepsWholeRowSnapping() throws {
    ScrollSettings.setMode(.lineQuantized)
    try withSoftwareRenderer {
      let (view, model, cellHeight) = try makeView(rows: 6, cols: 40)
      let activeTab = try XCTUnwrap(model.activeTab)
      let session = try XCTUnwrap(model.session(forTab: activeTab.id))

      session.write(Array((0..<120).map { "line \($0)\r\n" }.joined().utf8))
      view.advanceFrame()

      for _ in 0..<3 {
        view.scrollWheel(with: preciseWheel(rowsUp: 0.25, cellHeight: cellHeight))
      }
      var snap = view.debugScrollSnapshot()
      XCTAssertEqual(
        snap.displayed, 0, "sub-row deltas accumulate in the residual, not the viewport")
      XCTAssertEqual(try linesBack(session), 0)

      view.scrollWheel(with: preciseWheel(rowsUp: 0.25, cellHeight: cellHeight))
      snap = view.debugScrollSnapshot()
      XCTAssertEqual(snap.displayed, -1.0, "the fourth quarter-row completes a whole row")
      XCTAssertEqual(snap.displayed, Double(snap.applied), "quantized mode never holds a fraction")
      XCTAssertEqual(try linesBack(session), 1)
    }
  }
}
