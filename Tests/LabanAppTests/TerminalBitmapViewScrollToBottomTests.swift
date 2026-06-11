import AppKit
import CoreGraphics
import LabanCore
import LabanRenderer
import LabanTerminalCore
import XCTest

@testable import LabanApp

/// Regression: a non-alt-screen app (e.g. Codex CLI) that streams output while
/// the user is scrolled back into Laban-owned scrollback moves the live bottom
/// away. Scrolling "all the way down" must re-engage the active bottom so the
/// overlay scroll indicator hides — it previously stalled on a stale pin short
/// of the live bottom because the smooth-scroll accountant treated its cached
/// `appliedScrollRows == 0` as the bottom instead of snapping to active.
final class TerminalBitmapViewScrollToBottomTests: XCTestCase {

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

  /// A precise (trackpad) wheel event scrolling `rows` rows. Positive = up
  /// (toward older history), negative = down (toward the live bottom), matching
  /// AppKit's sign convention.
  private func wheel(rowsUp: Int, cellHeight: Int) -> TestScrollWheelEvent {
    TestScrollWheelEvent(
      locationInWindow: CGPoint(x: SidebarLayout.defaultWidth + 50, y: 50),
      deltaY: 0,
      scrollingDeltaY: CGFloat(rowsUp * cellHeight),
      hasPreciseScrollingDeltas: true
    )
  }

  /// Precise input drives the target accumulator; the rendered position
  /// chases it through the per-tick PD resampler. Run ticks until it
  /// converges so the assertions below stay about destinations, not lag.
  private func converge(_ view: TerminalBitmapView) {
    for _ in 0..<500 {
      view.advanceFrame()
      let snap = view.debugScrollSnapshot()
      if !snap.animating && snap.displayed == snap.target { return }
      usleep(2000)
    }
  }

  func testScrollToBottomReengagesActiveAfterStreamingWhileScrolledBack() throws {
    try withSoftwareRenderer {
      let (view, model, cellHeight) = try makeView(rows: 6, cols: 40)
      let activeTab = try XCTUnwrap(model.activeTab)
      let session = try XCTUnwrap(model.session(forTab: activeTab.id))

      func stream(_ range: Range<Int>) {
        session.write(Array(range.map { "line \($0)\r\n" }.joined().utf8))
        view.advanceFrame()
      }
      func linesBack() throws -> Int {
        let vs = try XCTUnwrap(session.viewportState())
        return max(0, max(0, vs.totalRows - vs.viewportRows) - vs.viewportOffset)
      }

      // Long conversation history; user is at the live bottom.
      stream(0..<120)
      XCTAssertEqual(try linesBack(), 0, "starts pinned to the bottom")

      // User scrolls up ~30 rows to re-read earlier output.
      view.scrollWheel(with: wheel(rowsUp: 30, cellHeight: cellHeight))
      converge(view)
      XCTAssertGreaterThan(try linesBack(), 0, "scrolled back into history")

      // Codex keeps streaming while the user is scrolled back — this pushes the
      // live bottom well past where the user's down-scroll would otherwise land.
      stream(120..<200)
      let backlog = try linesBack()
      XCTAssertGreaterThan(backlog, 30, "streamed output moved the live bottom away")

      // User scrolls down by the same ~30 rows they went up. Pre-fix this left
      // them ~80 rows short of the live bottom; the snap-to-active makes it land
      // on the bottom regardless of how far output moved it.
      view.scrollWheel(with: wheel(rowsUp: -30, cellHeight: cellHeight))
      converge(view)
      XCTAssertEqual(
        try linesBack(), 0,
        "scroll-to-bottom must reach the live bottom even though output streamed past it")

      // And it must stay pinned as more output arrives (viewport is active).
      stream(200..<240)
      XCTAssertEqual(
        try linesBack(), 0,
        "after reaching the bottom the viewport must follow new output")

      // The overlay indicator agrees: not held, no pill.
      let vs = try XCTUnwrap(session.viewportState())
      let out = TerminalScrollIndicator.decide(
        .init(
          viewportOffset: vs.viewportOffset, totalRows: vs.totalRows,
          viewportRows: vs.viewportRows, isHoverEdge: false,
          isAltScreen: vs.altScreen, isMouseTracking: vs.mouseTracking))
      XCTAssertFalse(out.shouldHold)
      XCTAssertFalse(out.pillVisible)
    }
  }

  /// The exact case from a user capture: a non-alt-screen app (Codex) streams
  /// ~1 row per frame while the user nudges *down* one row at a time near the
  /// bottom. Each 1-row down-scroll is matched by a streamed row, and the
  /// smooth-scroll accountant's clamp-reset pulls `targetScrollRows` back, so a
  /// bounded scroll never lands exactly on the moving bottom — the
  /// `targetScrollRows == 0` snap never fires and the overlay indicator stays
  /// stuck a row short. A downward step that reconciles further from the bottom
  /// than it aimed must pin to active so follow-output re-engages.
  func testIncrementalScrollDownDuringStreamingReachesBottom() throws {
    try withSoftwareRenderer {
      let (view, model, cellHeight) = try makeView(rows: 6, cols: 40)
      let activeTab = try XCTUnwrap(model.activeTab)
      let session = try XCTUnwrap(model.session(forTab: activeTab.id))

      var nextLine = 0
      func stream(_ count: Int) {
        var text = ""
        for _ in 0..<count {
          text += "line \(nextLine)\r\n"
          nextLine += 1
        }
        session.write(Array(text.utf8))
        view.advanceFrame()
      }
      func linesBack() throws -> Int {
        let vs = try XCTUnwrap(session.viewportState())
        return max(0, max(0, vs.totalRows - vs.viewportRows) - vs.viewportOffset)
      }

      stream(120)
      XCTAssertEqual(try linesBack(), 0, "starts pinned to the bottom")

      // User scrolls up a few rows to re-read recent output.
      view.scrollWheel(with: wheel(rowsUp: 3, cellHeight: cellHeight))
      converge(view)
      XCTAssertGreaterThan(try linesBack(), 0, "scrolled back into history")

      // Now nudge down one row per frame while output streams one row per frame.
      // Pre-fix every nudge is cancelled by a streamed row and this stalls a row
      // or two short forever; the snap-to-active must catch the receding bottom.
      for _ in 0..<30 {
        stream(1)
        view.scrollWheel(with: wheel(rowsUp: -1, cellHeight: cellHeight))
        view.advanceFrame()
      }
      converge(view)
      XCTAssertEqual(
        try linesBack(), 0,
        "incremental scroll-down during streaming must reach and follow the live bottom")

      // And it must stay pinned as more output arrives (viewport is active).
      stream(5)
      XCTAssertEqual(try linesBack(), 0, "after reaching the bottom the viewport must follow")
    }
  }

  /// Guards the streaming follow-snap against over-reach: a small down-scroll
  /// deep in history (the user is navigating, not returning to the bottom) must
  /// NOT snap to the live bottom even though streaming moved the bottom past the
  /// step. Only steps that land within a few rows of the bottom re-engage follow.
  func testDeepHistoryDownScrollDuringStreamingStaysInHistory() throws {
    try withSoftwareRenderer {
      let (view, model, cellHeight) = try makeView(rows: 6, cols: 40)
      let activeTab = try XCTUnwrap(model.activeTab)
      let session = try XCTUnwrap(model.session(forTab: activeTab.id))

      func linesBack() throws -> Int {
        let vs = try XCTUnwrap(session.viewportState())
        return max(0, max(0, vs.totalRows - vs.viewportRows) - vs.viewportOffset)
      }

      session.write(Array((0..<120).map { "line \($0)\r\n" }.joined().utf8))
      view.advanceFrame()

      // Scroll far up into history.
      view.scrollWheel(with: wheel(rowsUp: 60, cellHeight: cellHeight))
      converge(view)
      // App streams a large burst while the user reads deep in history, moving
      // the live bottom far past where a small down-scroll would land.
      session.write(Array((120..<180).map { "line \($0)\r\n" }.joined().utf8))
      view.advanceFrame()
      let deep = try linesBack()
      XCTAssertGreaterThan(deep, 50, "user is deep in history with the bottom far below")

      // A small down-scroll (navigation, not a return-to-bottom) lands short of
      // its aim because output streamed — but it is nowhere near the bottom, so
      // it must stay in history rather than snapping to follow.
      view.scrollWheel(with: wheel(rowsUp: -5, cellHeight: cellHeight))
      converge(view)
      XCTAssertGreaterThan(
        try linesBack(), 30,
        "a small down-scroll deep in history must not snap to the live bottom")
    }
  }

  /// A partial scroll-up that the user does NOT fully reverse must remain
  /// scrolled back — the snap only fires when the user actually returns to the
  /// bottom, so normal mid-history reading is unaffected.
  func testPartialScrollDownStaysScrolledBack() throws {
    try withSoftwareRenderer {
      let (view, model, cellHeight) = try makeView(rows: 6, cols: 40)
      let activeTab = try XCTUnwrap(model.activeTab)
      let session = try XCTUnwrap(model.session(forTab: activeTab.id))

      session.write(Array((0..<120).map { "line \($0)\r\n" }.joined().utf8))
      view.advanceFrame()

      view.scrollWheel(with: wheel(rowsUp: 40, cellHeight: cellHeight))
      converge(view)
      // Scroll back down only 10 of the 40 rows.
      view.scrollWheel(with: wheel(rowsUp: -10, cellHeight: cellHeight))
      converge(view)

      let vs = try XCTUnwrap(session.viewportState())
      let linesBack = max(0, max(0, vs.totalRows - vs.viewportRows) - vs.viewportOffset)
      XCTAssertGreaterThan(
        linesBack, 0, "a partial down-scroll must not snap to the bottom")
    }
  }
}
