import Darwin
import LabanTerminalCore
import XCTest

/// M0 — Characterization harness for DEC private mode 2027 (grapheme-cluster
/// width). This milestone MEASURES what the vendored `libghostty-vt` engine
/// already does through Laban's bridge, BEFORE any code change. Where the engine
/// behaves as the plan predicts, we assert it; where it does not, we record a
/// loud "GAP:" note (and fail) rather than silently passing.
///
/// Driving pattern is copied from
/// `LabanSessionTests.testDECRQMModeQueryUsesTerminalState`: a fixture session
/// (`laban_session_create` with `fixture_mode = 1`) consumes bytes via
/// `laban_session_write` (fixture mode forwards them straight to
/// `ghostty_terminal_vt_write` — no PTY), responses are read back with
/// `laban_session_drain_response`, and grid state is read from
/// `laban_session_snapshot`.
///
/// The probe subject is the "farmer" emoji `👩‍🌾`:
///   U+1F9D1 ZWJ U+200D U+1F33E
///   UTF-8 = F0 9F A7 91  E2 80 8D  F0 9F 8C BE
final class Mode2027CharacterizationTests: XCTestCase {

  // F0 9F A7 91 E2 80 8D F0 9F 8C BE
  private let farmer: [UInt8] = [
    0xF0, 0x9F, 0xA7, 0x91, 0xE2, 0x80, 0x8D, 0xF0, 0x9F, 0x8C, 0xBE,
  ]

  // MARK: - Session / IO helpers (mirror LabanSessionTests)

  private func makeFixtureSession(rows: Int32 = 24, cols: Int32 = 80) -> OpaquePointer? {
    var config = LabanLaunchConfig()
    config.fixture_mode = 1
    var size = LabanTerminalSize()
    size.rows = rows
    size.cols = cols
    var session: OpaquePointer?
    let result = laban_session_create(&config, size, &session)
    guard result == 0 else { return nil }
    return session
  }

  private func writeBytes(_ session: OpaquePointer, _ bytes: [UInt8]) {
    bytes.withUnsafeBytes { buf in
      _ = laban_session_write(
        session,
        buf.baseAddress?.assumingMemoryBound(to: UInt8.self),
        bytes.count)
    }
  }

  private func drainResponse(_ session: OpaquePointer) -> [UInt8] {
    var buf = [UInt8](repeating: 0, count: 256)
    var len: size_t = 0
    let r = laban_session_drain_response(session, &buf, buf.count, &len)
    XCTAssertEqual(r, 0, "drain_response must succeed")
    return Array(buf.prefix(Int(len)))
  }

  /// One printed cell described for the log/measurement table.
  private struct CellInfo: CustomStringConvertible {
    let col: Int
    let wide: UInt8
    let codepoint: UInt32
    let utf8: [UInt8]

    var wideName: String {
      switch wide {
      case 0: return "NARROW"
      case 1: return "WIDE"
      case 2: return "SPACER_TAIL"
      case 3: return "SPACER_HEAD"
      default: return "UNKNOWN(\(wide))"
      }
    }

    var utf8Hex: String {
      utf8.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    var description: String {
      "col=\(col) wide=\(wideName)(\(wide)) firstCP=U+\(String(format: "%04X", codepoint)) "
        + "utf8=[\(utf8Hex)] (\(utf8.count) bytes)"
    }
  }

  /// Snapshot the grid, returning (cursor_col, cursor_row, cols, printed cells of row 0).
  /// Only cells with non-zero utf8_length OR a spacer width are reported, so the
  /// caller sees exactly how the cluster was laid down.
  private func snapshotRow0(
    _ session: OpaquePointer
  ) -> (cursorCol: Int, cursorRow: Int, cols: Int, cells: [CellInfo])? {
    var snapPtr: UnsafeMutablePointer<LabanSnapshot>?
    guard laban_session_snapshot(session, &snapPtr) == 0, let snapPtr else { return nil }
    defer { laban_snapshot_destroy(snapPtr) }
    let snap = snapPtr.pointee
    let cols = Int(snap.cols)
    let cursorCol = Int(snap.cursor_col)
    let cursorRow = Int(snap.cursor_row)
    guard let cells = snap.cells, let storage = snap.utf8_storage else {
      return (cursorCol, cursorRow, cols, [])
    }
    var out: [CellInfo] = []
    for col in 0..<cols {
      let cell = cells[col]  // row 0 == cols offset 0
      let hasText = cell.utf8_length > 0
      let isSpacer = cell.wide == 2 || cell.wide == 3
      guard hasText || isSpacer else { continue }
      var bytes: [UInt8] = []
      if hasText {
        let base = UnsafeRawPointer(storage).advanced(by: Int(cell.utf8_offset))
        let buf = UnsafeBufferPointer<UInt8>(
          start: base.assumingMemoryBound(to: UInt8.self),
          count: Int(cell.utf8_length))
        bytes = Array(buf)
      }
      out.append(
        CellInfo(col: col, wide: cell.wide, codepoint: cell.codepoint, utf8: bytes))
    }
    return (cursorCol, cursorRow, cols, out)
  }

  private func logCells(_ label: String, _ result: (cursorCol: Int, cursorRow: Int, cols: Int, cells: [CellInfo])) {
    print("M0 \(label): cursor_col=\(result.cursorCol) cursor_row=\(result.cursorRow) cols=\(result.cols)")
    if result.cells.isEmpty {
      print("M0 \(label):   (no printed/spacer cells in row 0)")
    }
    for c in result.cells {
      print("M0 \(label):   \(c)")
    }
  }

  private func hex(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
  }

  private func describe(_ bytes: [UInt8]) -> String {
    let s = String(bytes: bytes, encoding: .utf8) ?? "<non-utf8>"
    return "\(s.debugDescription) hex=[\(hex(bytes))]"
  }

  // MARK: - Probe A: mode OFF (default) layout

  func testProbeA_modeOFF_farmerLayout() {
    guard let session = makeFixtureSession() else {
      XCTFail("laban_session_create returned non-zero")
      return
    }
    defer { laban_session_destroy(session) }

    // Default: mode 2027 OFF. Print the farmer emoji.
    writeBytes(session, farmer)

    guard let r = snapshotRow0(session) else {
      XCTFail("snapshot failed")
      return
    }
    logCells("ProbeA(OFF)", r)

    // Expectation from research: legacy per-codepoint layout (~4 columns):
    // U+1F9D1 (wide=2) + U+200D (zero) + U+1F33E (wide=2) = 4 cells.
    // We RECORD the actual cursor column; assert the broad shape (>2 cols, the
    // legacy multi-cell layout) but do not hard-pin the exact count in case the
    // engine's legacy rule differs slightly — the precise number is the
    // measurement this probe exists to capture.
    if r.cursorCol == 2 {
      print(
        "M0 ProbeA(OFF): GAP/NOTE: cursor advanced only 2 cols with mode OFF — "
          + "engine may be clustering by default (unexpected; plan assumes legacy ~4).")
    }
    XCTAssertGreaterThanOrEqual(
      r.cursorCol, 3,
      "Mode OFF should use legacy per-codepoint width (~4 cols); got cursor_col=\(r.cursorCol)")
  }

  // MARK: - Probe B: mode ON layout

  func testProbeB_modeON_farmerLayout() {
    guard let session = makeFixtureSession() else {
      XCTFail("laban_session_create returned non-zero")
      return
    }
    defer { laban_session_destroy(session) }

    // Enable mode 2027, then print the farmer emoji.
    writeBytes(session, Array("\u{1b}[?2027h".utf8))
    writeBytes(session, farmer)

    guard let r = snapshotRow0(session) else {
      XCTFail("snapshot failed")
      return
    }
    logCells("ProbeB(ON)", r)

    // Expectation: 2 columns — one WIDE head cell carrying the full cluster
    // bytes + one SPACER_TAIL.
    XCTAssertEqual(
      r.cursorCol, 2,
      "Mode ON should lay the cluster as a single 2-col grapheme; got cursor_col=\(r.cursorCol)")

    // Head cell at col 0 must carry ALL cluster bytes and be WIDE.
    if let head = r.cells.first(where: { $0.col == 0 }) {
      XCTAssertEqual(
        head.wide, 1,
        "Mode ON head cell should be WIDE(1); got \(head.wideName)")
      XCTAssertEqual(
        head.utf8, farmer,
        "Mode ON head cell must carry the full cluster bytes; got [\(head.utf8Hex)]")
    } else {
      XCTFail("Mode ON: no head cell found at col 0")
    }

    // Cell at col 1 must be a SPACER_TAIL.
    if let tail = r.cells.first(where: { $0.col == 1 }) {
      XCTAssertEqual(
        tail.wide, 2,
        "Mode ON col 1 should be SPACER_TAIL(2); got \(tail.wideName)")
    } else {
      print("M0 ProbeB(ON): GAP/NOTE: no spacer-tail cell recorded at col 1")
    }
  }

  // MARK: - Probe C: DECRQM handshake (set + reset)

  func testProbeC_decrqmHandshake() {
    // --- When SET ---
    guard let setSession = makeFixtureSession() else {
      XCTFail("laban_session_create returned non-zero")
      return
    }
    writeBytes(setSession, Array("\u{1b}[?2027h".utf8))
    _ = drainResponse(setSession)  // DECSET itself emits nothing; clear just in case.
    writeBytes(setSession, Array("\u{1b}[?2027$p".utf8))
    let setReply = drainResponse(setSession)
    laban_session_destroy(setSession)
    print("M0 ProbeC(set): DECRQM ?2027$p reply = \(describe(setReply))")

    // --- When RESET ---
    guard let resetSession = makeFixtureSession() else {
      XCTFail("laban_session_create returned non-zero")
      return
    }
    // Default is reset; query without enabling.
    writeBytes(resetSession, Array("\u{1b}[?2027$p".utf8))
    let resetReplyDefault = drainResponse(resetSession)
    print("M0 ProbeC(reset-default): DECRQM ?2027$p reply = \(describe(resetReplyDefault))")
    // Also explicitly toggle on then off, to exercise the reset path.
    writeBytes(resetSession, Array("\u{1b}[?2027h".utf8))
    _ = drainResponse(resetSession)
    writeBytes(resetSession, Array("\u{1b}[?2027l".utf8))
    _ = drainResponse(resetSession)
    writeBytes(resetSession, Array("\u{1b}[?2027$p".utf8))
    let resetReply = drainResponse(resetSession)
    laban_session_destroy(resetSession)
    print("M0 ProbeC(reset-after-toggle): DECRQM ?2027$p reply = \(describe(resetReply))")

    // Decode the DECRPM value from a reply of form ESC [ ? 2027 ; <v> $ y.
    func decrpmValue(_ bytes: [UInt8]) -> Int? {
      guard let s = String(bytes: bytes, encoding: .utf8) else { return nil }
      // Expect prefix "\u{1b}[?2027;" and suffix "$y".
      guard s.hasPrefix("\u{1b}[?2027;"), s.hasSuffix("$y") else { return nil }
      let mid = s.dropFirst("\u{1b}[?2027;".count).dropLast("$y".count)
      return Int(mid)
    }

    let setVal = decrpmValue(setReply)
    let resetVal = decrpmValue(resetReply)
    print("M0 ProbeC: DECRPM value when SET = \(setVal.map(String.init) ?? "nil")")
    print("M0 ProbeC: DECRPM value when RESET = \(resetVal.map(String.init) ?? "nil")")

    // GAP detection: an empty reply means the engine did not answer DECRQM for
    // 2027 (it must be answered for the handshake to work). Record loudly.
    if setReply.isEmpty {
      XCTFail(
        "GAP: DECRQM ?2027$p produced NO response when mode is SET. "
          + "The handshake is broken — TUIs cannot negotiate mode 2027.")
    } else {
      // The plan's Decision Log expects SET=1 (genuinely toggleable). Record the
      // actual value; flag if it is not 1 (could be 3 = permanently set).
      XCTAssertNotNil(
        setVal, "DECRQM SET reply not in DECRPM form; got \(describe(setReply))")
      if let setVal, setVal != 1 {
        print(
          "M0 ProbeC: NOTE: DECRPM value when SET is \(setVal), not 1. "
            + "Plan assumed 1 (toggleable); engine reports \(setVal) "
            + "(\(decrpmName(setVal))). Defer to engine and record in plan.")
      }
      XCTAssertEqual(
        setVal, 1,
        "Plan Decision Log expects DECRPM SET=1 for mode 2027; engine returned "
          + "\(setVal.map(String.init) ?? "nil") — record this in Surprises & Discoveries.")
    }

    if resetReply.isEmpty {
      XCTFail(
        "GAP: DECRQM ?2027$p produced NO response when mode is RESET. "
          + "The handshake is broken.")
    } else {
      XCTAssertNotNil(
        resetVal, "DECRQM RESET reply not in DECRPM form; got \(describe(resetReply))")
      if let resetVal, resetVal != 2 {
        print(
          "M0 ProbeC: NOTE: DECRPM value when RESET is \(resetVal), not 2 "
            + "(\(decrpmName(resetVal))).")
      }
      XCTAssertEqual(
        resetVal, 2,
        "Plan Decision Log expects DECRPM RESET=2 for mode 2027; engine returned "
          + "\(resetVal.map(String.init) ?? "nil").")
    }
  }

  private func decrpmName(_ v: Int) -> String {
    switch v {
    case 0: return "NOT_RECOGNIZED"
    case 1: return "SET"
    case 2: return "RESET"
    case 3: return "PERMANENTLY_SET"
    case 4: return "PERMANENTLY_RESET"
    default: return "UNKNOWN"
    }
  }

  // MARK: - Probe D: cursor position report (CSI 6n)

  func testProbeD_cursorReport_bothModes() {
    // CSI 6n reply is ESC [ <row> ; <col> R  (1-based).
    func cprColumn(_ bytes: [UInt8]) -> (row: Int, col: Int)? {
      guard let s = String(bytes: bytes, encoding: .utf8) else { return nil }
      guard s.hasPrefix("\u{1b}["), s.hasSuffix("R") else { return nil }
      let mid = s.dropFirst(2).dropLast()  // strip ESC[ and R
      let parts = mid.split(separator: ";")
      guard parts.count == 2, let row = Int(parts[0]), let col = Int(parts[1]) else {
        return nil
      }
      return (row, col)
    }

    // OFF
    guard let off = makeFixtureSession() else {
      XCTFail("laban_session_create returned non-zero")
      return
    }
    writeBytes(off, farmer)
    writeBytes(off, Array("\u{1b}[6n".utf8))
    let offReply = drainResponse(off)
    laban_session_destroy(off)
    let offCpr = cprColumn(offReply)
    print(
      "M0 ProbeD(OFF): CSI 6n reply = \(describe(offReply)) -> "
        + "row=\(offCpr?.row.description ?? "?") col=\(offCpr?.col.description ?? "?")")

    // ON
    guard let on = makeFixtureSession() else {
      XCTFail("laban_session_create returned non-zero")
      return
    }
    writeBytes(on, Array("\u{1b}[?2027h".utf8))
    writeBytes(on, farmer)
    writeBytes(on, Array("\u{1b}[6n".utf8))
    let onReply = drainResponse(on)
    laban_session_destroy(on)
    let onCpr = cprColumn(onReply)
    print(
      "M0 ProbeD(ON): CSI 6n reply = \(describe(onReply)) -> "
        + "row=\(onCpr?.row.description ?? "?") col=\(onCpr?.col.description ?? "?")")

    XCTAssertNotNil(offCpr, "GAP: CSI 6n produced no/invalid CPR when mode OFF")
    XCTAssertNotNil(onCpr, "GAP: CSI 6n produced no/invalid CPR when mode ON")

    // 1-based column == cells advanced + 1. ON should report a smaller column
    // than OFF (cluster collapses to 2 cells), i.e. ON col == 3 (cursor after 2
    // cells), OFF col > 3.
    if let onCpr {
      XCTAssertEqual(
        onCpr.col, 3,
        "Mode ON: CSI 6n should report column 3 (cursor after a 2-cell cluster); "
          + "got \(onCpr.col)")
    }
    if let offCpr {
      XCTAssertGreaterThanOrEqual(
        offCpr.col, 4,
        "Mode OFF: CSI 6n should report a legacy (>=4) column; got \(offCpr.col)")
    }
  }

  // MARK: - Probe E: mid-session flip (CRITICAL)

  /// Extract every terminal row (scrollback + viewport) as plain text and return
  /// the rows. Uses the same `laban_session_scrollback_extract*` path the Swift
  /// scrollback find/copy fallback uses — the path the plan flags as the genuine
  /// width-drift bug.
  private func extractAllRows(_ session: OpaquePointer) -> [String]? {
    var rows: size_t = 0
    var cap: size_t = 0
    guard laban_session_scrollback_extract_size(session, 0, 0, &rows, &cap) == 0 else {
      return nil
    }
    guard rows > 0, cap > 0 else { return [] }
    var text = [CChar](repeating: 0, count: Int(cap))
    var rowOffsets = [UInt32](repeating: 0, count: Int(rows))
    var outRows: size_t = 0
    var outTextLen: size_t = 0
    var reqText: size_t = 0
    var reqOffsets: size_t = 0
    let r = laban_session_scrollback_extract(
      session, 0, 0,
      &text, text.count,
      &rowOffsets, rowOffsets.count,
      &outRows, &outTextLen, &reqText, &reqOffsets)
    guard r == 0 else { return nil }
    // text is NUL-terminated, rows separated by '\n'. Split into rows using
    // rowOffsets for exactness.
    let bytes = text.prefix(Int(outTextLen)).map { UInt8(bitPattern: $0) }
    var result: [String] = []
    for i in 0..<Int(outRows) {
      let start = Int(rowOffsets[i])
      let end = (i + 1 < Int(outRows)) ? Int(rowOffsets[i + 1]) : Int(outTextLen)
      // The byte just before `end` (for non-last rows) is the '\n' separator.
      var sliceEnd = end
      if sliceEnd > start, sliceEnd <= bytes.count, bytes[sliceEnd - 1] == 0x0A {
        sliceEnd -= 1
      }
      let slice = Array(bytes[start..<min(sliceEnd, bytes.count)])
      result.append(String(bytes: slice, encoding: .utf8) ?? "<non-utf8>")
    }
    return result
  }

  func testProbeE_midSessionFlip_scrollbackWidth() {
    // Small grid so we can push the cluster off the live viewport quickly.
    guard let session = makeFixtureSession(rows: 4, cols: 80) else {
      XCTFail("laban_session_create returned non-zero")
      return
    }
    defer { laban_session_destroy(session) }

    // 1) Mode ON, print the farmer emoji on row 0.
    writeBytes(session, Array("\u{1b}[?2027h".utf8))
    writeBytes(session, farmer)
    writeBytes(session, [0x0D])  // CR to col 0

    // Confirm it laid down as 2 cells while ON (sanity for the probe).
    if let live = snapshotRow0(session) {
      logCells("ProbeE(ON, live before scroll)", live)
    }

    // 2) Scroll it OFF the live viewport: emit enough newlines to push row 0
    // into scrollback. rows=4, so >4 line feeds guarantees it scrolled off.
    writeBytes(session, Array(repeating: 0x0A, count: 12))  // 12 LFs

    // 3) Flip mode OFF.
    writeBytes(session, Array("\u{1b}[?2027l".utf8))

    // 4) Run the scrollback extraction (the String-only fallback path).
    guard let allRows = extractAllRows(session) else {
      XCTFail("scrollback extraction failed")
      return
    }

    // Find the row that contains the farmer cluster bytes.
    let farmerStr = String(bytes: farmer, encoding: .utf8)!
    var clusterRowIndex: Int? = nil
    for (i, row) in allRows.enumerated() where row.contains(farmerStr) {
      clusterRowIndex = i
      break
    }

    guard let idx = clusterRowIndex else {
      print("M0 ProbeE: extracted rows (first 8):")
      for (i, row) in allRows.prefix(8).enumerated() {
        print("M0 ProbeE:   row[\(i)] = \(row.debugDescription)")
      }
      XCTFail(
        "GAP: farmer cluster not found in extracted scrollback rows "
          + "(\(allRows.count) rows). Cannot determine retained width.")
      return
    }

    let clusterRow = allRows[idx]
    // The scrollback extraction is a String with NO per-cell width metadata.
    // What it CAN tell us: how the extracted text represents the cluster.
    //   - If the cluster appears as the 3 raw code points with no padding,
    //     the extraction discarded width entirely (String fallback as documented).
    //   - We additionally report the byte content so M3 knows what's available.
    let utf8 = Array(clusterRow.utf8)
    // Trim trailing spaces for a clean view of the meaningful content.
    let trimmed = clusterRow.replacingOccurrences(
      of: "[ ]+$", with: "", options: .regularExpression)
    print("M0 ProbeE: cluster found in extracted row[\(idx)]")
    print("M0 ProbeE:   raw row.debugDescription = \(clusterRow.debugDescription)")
    print("M0 ProbeE:   trimmed = \(trimmed.debugDescription)")
    print("M0 ProbeE:   row utf8 (first 32 bytes) = [\(hex(Array(utf8.prefix(32))))]")
    print("M0 ProbeE:   row String.count (grapheme clusters) = \(clusterRow.count)")
    print("M0 ProbeE:   row unicodeScalars.count = \(clusterRow.unicodeScalars.count)")

    // The scrollback extraction returns ONE cluster's bytes regardless of mode
    // (it carries text, not width). The question for M3 is whether any width
    // information survives. Record the definitive answer:
    //   The String path collapses each grapheme to its raw bytes with NO spacer
    //   padding, so a downstream consumer MUST re-derive width from the String.
    //   That is exactly why M3 must carry engine width through the scrollback
    //   path. We assert the cluster bytes survive intact (the prerequisite for
    //   M3 to map them back to engine width).
    XCTAssertTrue(
      clusterRow.contains(farmerStr),
      "GAP: scrollback extraction lost the cluster bytes for the farmer emoji")

    // Determine the "column" a downstream String-only consumer would compute,
    // both ways, so the plan records the 2-vs-4 answer concretely.
    // (a) Per-grapheme count (what an engine-width-aware consumer wants): the
    //     cluster contributes 1 grapheme. (b) Per-scalar legacy table is what
    //     TerminalDisplayWidth does today.
    let leadingText = trimmed
    print(
      "M0 ProbeE: RESULT — scrollback extraction is String-only (no per-cell "
        + "width metadata). The extracted cluster row carries the full cluster "
        + "bytes (\(hex(farmer))) as ONE grapheme; any column must be re-derived "
        + "downstream. Leading content = \(leadingText.debugDescription). "
        + "This CONFIRMS M3's need to carry engine width through the scrollback "
        + "path (the String alone cannot disambiguate the 2-vs-4 width the engine "
        + "actually used).")
  }
}
