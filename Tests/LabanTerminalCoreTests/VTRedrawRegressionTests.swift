import LabanTerminalCore
import XCTest

// Regression tests for the rendering-overlap bug observed when running Claude
// Code inside Laban: orange "Tip:" footer text is visually layered over a
// streaming response paragraph. The visible symptom is two unrelated UI
// elements occupying the same row(s).
//
// These tests exercise the VT-level sequences a TUI like Claude Code uses to
// keep a footer pinned beneath streaming prose. Each test isolates one
// candidate sequence (CR + EL, cursor save/restore, scroll-region, cursor-up +
// EL) and asserts the resulting grid has no row mixing two logical elements.

final class VTRedrawRegressionTests: XCTestCase {

  private let esc = "\u{1B}"
  private let tip =
    "Tip: Run tasks in the cloud while you keep coding locally · Claude/web"

  // MARK: - Plain CR behavior (baseline; not a bug)

  /// Plain CR without EL: trailing chars from the prior line remain.
  /// This is how every VT works; documenting baseline so other tests can
  /// distinguish "we lack EL" from "EL is wrong".
  func testPlainCarriageReturnLeavesTrailingChars() {
    let session = makeFixtureSession(rows: 4, cols: 80)
    defer { laban_session_destroy(session) }

    feed(session, tip)
    feed(session, "\r")
    feed(session, "short")

    let row0 = rowText(session: session, row: 0)
    XCTAssertTrue(
      row0.hasPrefix("short"),
      "row 0 must start with 'short', got: \(row0)")
    XCTAssertTrue(
      row0.contains("Claude/web"),
      "without EL, trailing chars from the prior write must remain; got: \(row0)")
  }

  // MARK: - CR + EL

  /// CR + EL (CSI K) must clear from cursor to end of line so a shorter
  /// rewrite leaves no trailing chars from the prior write.
  func testCarriageReturnPlusELClearsTrailingChars() {
    let session = makeFixtureSession(rows: 4, cols: 80)
    defer { laban_session_destroy(session) }

    feed(session, tip)
    feed(session, "\r\(esc)[K")
    feed(session, "short")

    let row0 = rowText(session: session, row: 0)
    XCTAssertEqual(
      row0.trimmingCharacters(in: .whitespaces), "short",
      "CR + EL must clear trailing chars; got: \(row0)")
  }

  // MARK: - Cursor save/restore around scrolled prose (the suspected case)

  /// The pattern Claude Code uses: a footer is pinned at the bottom while
  /// prose streams in above it. Each new line of prose causes a scroll, and
  /// the footer is rewritten via cursor save/restore.
  ///
  /// Sequence under test:
  ///   1. write prose lines
  ///   2. write footer
  ///   3. cursor up to footer row
  ///   4. EL footer
  ///   5. write more prose (which scrolls)
  ///   6. write new footer
  ///
  /// The bug shows up if scrolling does NOT shift the footer's old position
  /// — the new footer appears at a different row from the old, and old
  /// footer chars persist where the prose now sits.
  func testFooterRedrawAfterScroll() {
    let session = makeFixtureSession(rows: 6, cols: 80)
    defer { laban_session_destroy(session) }

    // Fill rows 0..3 with prose, row 4 with footer, leave row 5 empty.
    feed(session, "prose-line-1\r\n")
    feed(session, "prose-line-2\r\n")
    feed(session, "prose-line-3\r\n")
    feed(session, "prose-line-4\r\n")
    feed(session, tip)

    // Now: cursor is at end of footer (row 4). Walk up to start of footer,
    // EL, and write a new prose line that pushes old prose up and old footer
    // down. Then rewrite footer.
    feed(session, "\r\(esc)[K")
    feed(session, "prose-line-5\r\n")
    feed(session, tip)

    dumpGrid(session: session, label: "after footer redraw")

    // No row should contain content from BOTH the prose stream and the tip.
    for row in 0..<6 {
      let text = rowText(session: session, row: row)
      let hasTip = text.contains("Tip:")
      let hasProse = text.contains("prose-line")
      XCTAssertFalse(
        hasTip && hasProse,
        "row \(row) mixes footer and prose: \(text)")
    }
  }

  // MARK: - Cursor up + EL (no save/restore)

  /// Common TUI redraw: cursor up N, EL, write new content. If EL or cursor
  /// up are mishandled, prior content overlaps with new content.
  func testCursorUpThenEL() {
    let session = makeFixtureSession(rows: 4, cols: 80)
    defer { laban_session_destroy(session) }

    feed(session, "first line of content here\r\n")
    feed(session, tip)

    // Cursor up to row 0, CR to col 0, EL, rewrite shorter content.
    feed(session, "\(esc)[1A\r\(esc)[K")
    feed(session, "second")

    let row0 = rowText(session: session, row: 0)
    XCTAssertEqual(
      row0.trimmingCharacters(in: .whitespaces), "second",
      "cursor-up + EL must clear row; got: \(row0)")
    let row1 = rowText(session: session, row: 1)
    XCTAssertTrue(
      row1.contains("Tip:"),
      "row 1 (footer) must be untouched; got: \(row1)")
  }

  // MARK: - Scroll region (DECSTBM)

  /// Claude Code may use DECSTBM to constrain scrolling to a top region so
  /// the footer rows below stay pinned. The bug would be: scroll inside the
  /// region nonetheless shifts the footer.
  func testScrollRegionPreservesFooter() {
    let session = makeFixtureSession(rows: 6, cols: 80)
    defer { laban_session_destroy(session) }

    // Set scroll region to rows 1..4 (DECSTBM uses 1-based). Row 0 and row 5
    // should be outside the scroll region.
    feed(session, "\(esc)[2;5r")

    // Move to row 5 and write footer.
    feed(session, "\(esc)[6;1H")
    feed(session, tip)

    // Move into scroll region and produce 5 newlines to trigger scrolling.
    feed(session, "\(esc)[2;1H")
    for i in 1...5 {
      feed(session, "prose-line-\(i)\r\n")
    }

    dumpGrid(session: session, label: "after scroll region")

    let footerRow = rowText(session: session, row: 5)
    XCTAssertTrue(
      footerRow.contains("Tip:"),
      "DECSTBM scroll must not displace footer at row 5; got: \(footerRow)")
    XCTAssertFalse(
      footerRow.contains("prose-line"),
      "row 5 must not contain prose; got: \(footerRow)")
  }

  // MARK: - Synchronized output (DEC mode 2026 / BSU+ESU)

  /// Claude Code uses synchronized output to atomically present frames. If
  /// the VT does not honor BSU/ESU, mid-frame partial state could be visible.
  /// This test asserts that the final state after BSU+content+ESU is correct.
  func testSynchronizedOutputBSUESU() {
    let session = makeFixtureSession(rows: 4, cols: 80)
    defer { laban_session_destroy(session) }

    feed(session, tip)
    // BSU
    feed(session, "\(esc)[?2026h")
    // Cursor home, EL, write replacement
    feed(session, "\(esc)[H\(esc)[K")
    feed(session, "replacement footer line")
    // ESU
    feed(session, "\(esc)[?2026l")

    let row0 = rowText(session: session, row: 0)
    XCTAssertEqual(
      row0.trimmingCharacters(in: .whitespaces),
      "replacement footer line",
      "BSU+ESU framed redraw must replace the line cleanly; got: \(row0)")
  }

  func testSynchronizedOutputModeQueryTracksBSUESU() {
    let session = makeFixtureSession(rows: 4, cols: 80)
    defer { laban_session_destroy(session) }

    var active: Int32 = -1
    XCTAssertEqual(laban_session_synchronized_output_active(session, &active), 0)
    XCTAssertEqual(active, 0)

    feed(session, "\(esc)[?2026h")
    XCTAssertEqual(laban_session_synchronized_output_active(session, &active), 0)
    XCTAssertEqual(active, 1)

    XCTAssertEqual(laban_session_reset_synchronized_output(session), 0)
    XCTAssertEqual(laban_session_synchronized_output_active(session, &active), 0)
    XCTAssertEqual(active, 0)

    feed(session, "\(esc)[?2026h")
    XCTAssertEqual(laban_session_synchronized_output_active(session, &active), 0)
    XCTAssertEqual(active, 1)

    feed(session, "\(esc)[?2026l")
    XCTAssertEqual(laban_session_synchronized_output_active(session, &active), 0)
    XCTAssertEqual(active, 0)
  }

  // MARK: - DECSET 1049 (alternate screen)

  /// Common pattern: enter alt screen for a TUI, exit to restore. Verifies
  /// primary content survives and alt-screen content doesn't leak in.
  func testAlternateScreenEnterExit() {
    let session = makeFixtureSession(rows: 4, cols: 80)
    defer { laban_session_destroy(session) }

    feed(session, "primary line 1\r\n")
    feed(session, "primary line 2")

    // Enter alt screen (1049 = save cursor + use alt screen + clear).
    feed(session, "\(esc)[?1049h")
    feed(session, "alt screen content here")

    // Exit alt screen.
    feed(session, "\(esc)[?1049l")

    let row0 = rowText(session: session, row: 0)
    let row1 = rowText(session: session, row: 1)
    XCTAssertTrue(
      row0.contains("primary line 1"),
      "row 0 must restore primary content; got: \(row0)")
    XCTAssertTrue(
      row1.contains("primary line 2"),
      "row 1 must restore primary content; got: \(row1)")
    XCTAssertFalse(
      row0.contains("alt screen") || row1.contains("alt screen"),
      "alt-screen content must not leak into primary; rows: \(row0) | \(row1)")
  }

  /// Exiting the alternate screen must mark every visible row dirty.
  ///
  /// Repro for the "black flash" seen running `btop`, quitting it, then
  /// `top`: the renderer keeps a persistent target and only repaints rows
  /// libghostty reports as dirty. The alt screen (btop) painted every row;
  /// when `?1049l` restores the primary screen, the primary rows did not
  /// themselves change, so their dirty bits can stay clean — partial damage
  /// then leaves the alt screen's pixels on screen until the shell happens
  /// to rewrite each row. Every visible row genuinely changed, so every row
  /// must be reported dirty.
  func testAlternateScreenExitMarksAllRowsDirty() {
    let session = makeFixtureSession(rows: 4, cols: 80)
    defer { laban_session_destroy(session) }

    feed(session, "primary line 1\r\n")
    feed(session, "primary line 2")

    // Render the primary screen and clear dirty state, mirroring the frame
    // loop (snapshot → render → mark_rendered).
    renderFrame(session)

    // Enter the alt screen, paint it, and render+clear again — this is the
    // "btop is running" steady state.
    feed(session, "\(esc)[?1049h")
    feed(session, "alt screen content here")
    renderFrame(session)

    // Exit the alt screen. The primary screen is restored.
    feed(session, "\(esc)[?1049l")

    let dirty = dirtyRows(session: session)
    XCTAssertEqual(
      dirty.count, 4, "snapshot must report per-row dirty bits; got \(dirty)")
    XCTAssertTrue(
      dirty.allSatisfy { $0 },
      "every row must be dirty after exiting the alt screen; got \(dirty)")
  }

  // MARK: - CSI J variants (erase in display)

  /// CSI 0J = erase from cursor to end of display.
  /// Claude Code may use CSI 0J to clear the bottom of the screen before
  /// rewriting. If misimplemented, rows below the cursor retain old content.
  func testEraseToEndOfDisplay() {
    let session = makeFixtureSession(rows: 6, cols: 80)
    defer { laban_session_destroy(session) }

    feed(session, "row 0 content here\r\n")
    feed(session, "row 1 content here\r\n")
    feed(session, "row 2 content here\r\n")
    feed(session, "row 3 content here\r\n")
    feed(session, tip)

    // Move cursor to row 2, col 0; erase to end of display.
    feed(session, "\(esc)[3;1H")
    feed(session, "\(esc)[0J")

    for row in 2..<6 {
      let text = rowText(session: session, row: row).trimmingCharacters(in: .whitespaces)
      XCTAssertEqual(text, "", "row \(row) must be empty after CSI 0J; got: \(text)")
    }
    let row1 = rowText(session: session, row: 1)
    XCTAssertTrue(
      row1.contains("row 1 content"), "row 1 (above cursor) must survive CSI 0J; got: \(row1)")
  }

  /// Reverse-Index (RI) scrolls down by one. A footer pinned at the bottom
  /// can be displaced if the VT mishandles RI at the top of the scroll
  /// region. Exercises whether prose inserted via RI can leak into the
  /// footer row.
  func testReverseIndexAtTop() {
    let session = makeFixtureSession(rows: 5, cols: 80)
    defer { laban_session_destroy(session) }

    feed(session, "row 0 prose line\r\n")
    feed(session, "row 1 prose line\r\n")
    feed(session, "row 2 prose line\r\n")
    feed(session, "row 3 prose line\r\n")
    feed(session, tip)

    // Cursor home, RI repeatedly to insert lines at top.
    feed(session, "\(esc)[H")
    for _ in 0..<3 {
      feed(session, "\(esc)M")  // RI
    }

    dumpGrid(session: session, label: "after RI x3 at top")

    // Footer should have scrolled down off-screen or remained at bottom
    // depending on how RI interacts with viewport. In either case, no row
    // should mix prose with footer.
    for row in 0..<5 {
      let text = rowText(session: session, row: row)
      XCTAssertFalse(
        text.contains("prose") && text.contains("Tip:"),
        "row \(row) mixes prose with footer after RI: \(text)")
    }
  }

  // MARK: - Helpers

  private func makeFixtureSession(rows: Int32, cols: Int32) -> OpaquePointer {
    var config = LabanLaunchConfig()
    config.fixture_mode = 1
    var size = LabanTerminalSize()
    size.rows = rows
    size.cols = cols
    var session: OpaquePointer?
    let r = laban_session_create(&config, size, &session)
    precondition(r == 0, "laban_session_create failed")
    return session!
  }

  private func feed(_ session: OpaquePointer, _ s: String) {
    let bytes = Array(s.utf8)
    _ = bytes.withUnsafeBytes { buf in
      laban_session_write(
        session,
        buf.baseAddress?.assumingMemoryBound(to: UInt8.self),
        bytes.count)
    }
  }

  /// Returns the text of one row, preserving column positions (empty cells
  /// become single spaces).
  private func rowText(session: OpaquePointer, row: Int) -> String {
    var snap: UnsafeMutablePointer<LabanSnapshot>?
    precondition(laban_session_snapshot(session, &snap) == 0)
    defer { laban_snapshot_destroy(snap) }
    let s = snap!.pointee
    let cols = Int(s.cols)
    guard let cells = s.cells, let storage = s.utf8_storage else { return "" }
    var line = ""
    for col in 0..<cols {
      let cell = cells[row * cols + col]
      if cell.utf8_length > 0 {
        let ptr = UnsafeRawPointer(storage).advanced(by: Int(cell.utf8_offset))
        let buf = UnsafeBufferPointer<UInt8>(
          start: ptr.assumingMemoryBound(to: UInt8.self),
          count: Int(cell.utf8_length))
        line += String(bytes: buf, encoding: .utf8) ?? " "
      } else {
        line += " "
      }
    }
    return line
  }

  /// Mirrors one frame of the render loop: take a snapshot (the renderer's
  /// damage input), then mark the frame rendered (clears dirty state).
  private func renderFrame(_ session: OpaquePointer) {
    var snap: UnsafeMutablePointer<LabanSnapshot>?
    precondition(laban_session_snapshot(session, &snap) == 0)
    laban_snapshot_destroy(snap)
    _ = laban_session_mark_rendered(session)
  }

  /// Returns the per-row dirty bits from a fresh snapshot.
  private func dirtyRows(session: OpaquePointer) -> [Bool] {
    var snap: UnsafeMutablePointer<LabanSnapshot>?
    precondition(laban_session_snapshot(session, &snap) == 0)
    defer { laban_snapshot_destroy(snap) }
    let s = snap!.pointee
    guard let dirty = s.dirty_rows else { return [] }
    return (0..<Int(s.dirty_row_count)).map { dirty[$0] != 0 }
  }

  private func dumpGrid(session: OpaquePointer, label: String) {
    var snap: UnsafeMutablePointer<LabanSnapshot>?
    precondition(laban_session_snapshot(session, &snap) == 0)
    defer { laban_snapshot_destroy(snap) }
    let s = snap!.pointee
    print("---- grid: \(label) (rows=\(s.rows), cols=\(s.cols)) ----")
    for row in 0..<Int(s.rows) {
      let line = rowText(session: session, row: row)
      print("[\(String(format: "%2d", row))] |\(line)|")
    }
    print("---- end grid ----")
  }
}
