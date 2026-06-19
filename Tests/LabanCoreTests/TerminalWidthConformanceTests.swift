import LabanCore
import LabanTerminalCore
import XCTest

/// M4 — Terminal width conformance fixture for DEC private mode 2027
/// (grapheme-cluster / Unicode core width).
///
/// This is the Review Gate's named fixture. For each spec-hard grapheme it drives
/// the REAL engine (a fixture `Session`) and, in BOTH mode OFF (default) and mode
/// ON (`ESC [ ? 2027 h`), pins:
///
///   (a) the engine grid layout — per-cell `wide` category (head + spacer tails)
///       plus `cursor_col` advance, cross-checked against the engine's own
///       `CSI 6n` cursor-position report (the value a negotiating program sees);
///   (b) the scrollback FIND column the engine actually laid down (start/end
///       column via `TerminalFind.search` over the M3 `ScrollbackBlock`
///       `graphemeWidths` v2 path), and the scrollback COPY bytes (via
///       `TerminalSelection.selectedText`, the `plainLineText` consumer).
///
/// Every numeric/enum expectation below is a LITERAL measured first through the
/// bridge (the measurement diagnostic test prints the full table). Hard-coding the
/// mode-ON values pins behavior AND supports the Review Gate mutation check:
/// flipping one expected ON value to its OFF value fails exactly that case.
///
/// Comparison strings are derived from the exact code-point scalars (never typed
/// emoji literals), so the bytes are unambiguous regardless of editor/normalization.
final class TerminalWidthConformanceTests: XCTestCase {

  // MARK: - Per-cell width category

  private enum Wide: UInt8, CustomStringConvertible {
    case narrow = 0
    case wide = 1
    case spacerTail = 2
    case spacerHead = 3
    var description: String {
      switch self {
      case .narrow: return "N"
      case .wide: return "W"
      case .spacerTail: return "T"
      case .spacerHead: return "H"
      }
    }
  }

  /// One conformance row.
  private struct Case {
    let name: String
    /// The exact Unicode scalars; UTF-8 bytes are derived from these.
    let scalars: [Unicode.Scalar]
    // Grid layout / advance (measured literals).
    let offLayout: [Wide]
    let offAdvance: Int
    let onLayout: [Wide]
    let onAdvance: Int
    // Scrollback find end-column (start is always 0; whole cluster at row start).
    let offFindEndColumn: Int
    let onFindEndColumn: Int

    var bytes: [UInt8] {
      var s = String.UnicodeScalarView()
      for sc in scalars { s.append(sc) }
      return Array(String(s).utf8)
    }
    var string: String {
      var s = String.UnicodeScalarView()
      for sc in scalars { s.append(sc) }
      return String(s)
    }
  }

  // Exact code points (derive bytes from scalars, never typed literals).
  private static func sc(_ v: UInt32) -> Unicode.Scalar { Unicode.Scalar(v)! }

  private let cases: [Case] = {
    let s = TerminalWidthConformanceTests.sc
    return [
      // ASCII a (U+0061): 1 cell both modes.
      Case(
        name: "ASCII a (U+0061)",
        scalars: [s(0x0061)],
        offLayout: [.narrow], offAdvance: 1,
        onLayout: [.narrow], onAdvance: 1,
        offFindEndColumn: 1, onFindEndColumn: 1),
      // CJK wide 中 (U+4E2D): WIDE+tail / 2 both modes.
      Case(
        name: "CJK 中 (U+4E2D)",
        scalars: [s(0x4E2D)],
        offLayout: [.wide, .spacerTail], offAdvance: 2,
        onLayout: [.wide, .spacerTail], onAdvance: 2,
        offFindEndColumn: 2, onFindEndColumn: 2),
      // ZWJ farmer U+1F9D1 U+200D U+1F33E (🧑‍🌾): OFF two clusters / 4; ON one / 2.
      Case(
        name: "ZWJ farmer (U+1F9D1 ZWJ U+1F33E)",
        scalars: [s(0x1F9D1), s(0x200D), s(0x1F33E)],
        offLayout: [.wide, .spacerTail, .wide, .spacerTail], offAdvance: 4,
        onLayout: [.wide, .spacerTail], onAdvance: 2,
        offFindEndColumn: 4, onFindEndColumn: 2),
      // ZWJ transgender flag U+1F3F3 U+FE0F U+200D U+26A7 U+FE0F (🏳️‍⚧️).
      // OFF: the two emoji bases (🏳 U+1F3F3, ⚧ U+26A7) are each NARROW because
      // their VS16 emoji-presentation only widens under clustering (the same VS16
      // nuance the standalone ▶️ case shows). ON collapses all 5 code points to a
      // single WIDE+tail cluster.
      Case(
        name: "ZWJ trans flag (U+1F3F3 VS16 ZWJ U+26A7 VS16)",
        scalars: [s(0x1F3F3), s(0xFE0F), s(0x200D), s(0x26A7), s(0xFE0F)],
        offLayout: [.narrow, .narrow], offAdvance: 2,
        onLayout: [.wide, .spacerTail], onAdvance: 2,
        offFindEndColumn: 2, onFindEndColumn: 2),
      // Regional-indicator flag pair U+1F1F8 U+1F1EA (🇸🇪).
      Case(
        name: "Regional flag (U+1F1F8 U+1F1EA)",
        scalars: [s(0x1F1F8), s(0x1F1EA)],
        offLayout: [.wide, .spacerTail, .wide, .spacerTail], offAdvance: 4,
        onLayout: [.wide, .spacerTail], onAdvance: 2,
        offFindEndColumn: 4, onFindEndColumn: 2),
      // Skin-tone modifier U+1F44B U+1F3FD (👋🏽).
      Case(
        name: "Skin-tone wave (U+1F44B U+1F3FD)",
        scalars: [s(0x1F44B), s(0x1F3FD)],
        offLayout: [.wide, .spacerTail, .wide, .spacerTail], offAdvance: 4,
        onLayout: [.wide, .spacerTail], onAdvance: 2,
        offFindEndColumn: 4, onFindEndColumn: 2),
      // Hangul syllable U+AC01 (각): precomposed, width 2.
      Case(
        name: "Hangul 각 (U+AC01)",
        scalars: [s(0xAC01)],
        offLayout: [.wide, .spacerTail], offAdvance: 2,
        onLayout: [.wide, .spacerTail], onAdvance: 2,
        offFindEndColumn: 2, onFindEndColumn: 2),
      // Devanagari cluster U+0915 U+094D U+0937 U+093F (क्षि): consonant + virama +
      // consonant + vowel sign — one human-perceived grapheme. MEASURED surprise:
      // OFF lays THREE narrow cells (advance 3) — the engine's legacy rule does not
      // collapse the conjunct (virama combines to 0, but the two consonants + the
      // vowel sign each take a cell); ON clusters the whole thing into ONE WIDE+tail
      // (advance 2). Both agree with the engine's own CSI 6n report, so this is the
      // engine's authoritative layout, not a Laban bug.
      Case(
        name: "Devanagari क्षि (U+0915 U+094D U+0937 U+093F)",
        scalars: [s(0x0915), s(0x094D), s(0x0937), s(0x093F)],
        offLayout: [.narrow, .narrow, .narrow], offAdvance: 3,
        onLayout: [.wide, .spacerTail], onAdvance: 2,
        offFindEndColumn: 3, onFindEndColumn: 2),
      // VS16 emoji presentation U+25B6 U+FE0F (▶️): OFF narrow/1, ON wide/2.
      Case(
        name: "VS16 ▶️ (U+25B6 U+FE0F)",
        scalars: [s(0x25B6), s(0xFE0F)],
        offLayout: [.narrow], offAdvance: 1,
        onLayout: [.wide, .spacerTail], onAdvance: 2,
        offFindEndColumn: 1, onFindEndColumn: 2),
      // VS15 text presentation U+25B6 U+FE0E (▶︎): narrow/1 both modes.
      Case(
        name: "VS15 ▶︎ (U+25B6 U+FE0E)",
        scalars: [s(0x25B6), s(0xFE0E)],
        offLayout: [.narrow], offAdvance: 1,
        onLayout: [.narrow], onAdvance: 1,
        offFindEndColumn: 1, onFindEndColumn: 1),
    ]
  }()

  // MARK: - Session helpers (drive the real engine through the Swift wrapper)

  private func makeSession(rows: Int32 = 24, cols: Int32 = 80) throws -> Session {
    var size = LabanTerminalSize()
    size.rows = rows
    size.cols = cols
    return try Session.fixture(size: size)
  }

  /// Occupied cells of row 0 (text-carrying or spacer), plus cursor column.
  private func occupiedRow0(_ session: Session) -> (cursorCol: Int, cells: [(wide: UInt8, utf8: [UInt8])])? {
    guard let snapPtr = session.snapshot() else { return nil }
    defer { laban_snapshot_destroy(snapPtr) }
    let snap = snapPtr.pointee
    let cols = Int(snap.cols)
    guard let cells = snap.cells, let storage = snap.utf8_storage else {
      return (Int(snap.cursor_col), [])
    }
    var out: [(wide: UInt8, utf8: [UInt8])] = []
    for col in 0..<cols {
      let cell = cells[col]
      let hasText = cell.utf8_length > 0
      let isSpacer = cell.wide == 2 || cell.wide == 3
      guard hasText || isSpacer else { continue }
      var bytes: [UInt8] = []
      if hasText {
        let base = UnsafeRawPointer(storage).advanced(by: Int(cell.utf8_offset))
        let buf = UnsafeBufferPointer<UInt8>(
          start: base.assumingMemoryBound(to: UInt8.self), count: Int(cell.utf8_length))
        bytes = Array(buf)
      }
      out.append((wide: cell.wide, utf8: bytes))
    }
    return (Int(snap.cursor_col), out)
  }

  /// Print bytes (optionally enabling mode 2027) then `CSI 6n`; return reported
  /// 1-based column.
  private func cprColumnAfter(_ bytes: [UInt8], modeOn: Bool) throws -> Int? {
    let session = try makeSession()
    defer { session.close() }
    if modeOn { _ = session.write(Array("\u{1b}[?2027h".utf8)) }
    _ = session.write(bytes)
    _ = session.write(Array("\u{1b}[6n".utf8))
    let reply = session.drainResponse()
    guard let str = String(bytes: reply, encoding: .utf8),
      str.hasPrefix("\u{1b}["), str.hasSuffix("R")
    else { return nil }
    let mid = str.dropFirst(2).dropLast()
    let parts = mid.split(separator: ";")
    guard parts.count == 2, let col = Int(parts[1]) else { return nil }
    return col
  }

  /// Place `bytes` on row 0, scroll it into history, return its `ScrollbackBlock`.
  private func scrollbackFor(_ bytes: [UInt8], modeOn: Bool) throws -> ScrollbackBlock? {
    var size = LabanTerminalSize()
    size.rows = 4
    size.cols = 80
    let session = try Session.fixture(size: size)
    defer { session.close() }
    if modeOn { _ = session.write(Array("\u{1b}[?2027h".utf8)) }
    _ = session.write(bytes)
    _ = session.write([0x0D])  // CR to col 0
    _ = session.write(Array(repeating: 0x0A, count: 12))  // LFs push row 0 to history
    return session.scrollbackBlock()
  }

  /// Copy the whole scrolled-off cluster row via the selection path.
  private func copyScrolledOffRow(_ bytes: [UInt8], modeOn: Bool) throws -> String? {
    var size = LabanTerminalSize()
    size.rows = 4
    size.cols = 80
    let session = try Session.fixture(size: size)
    defer { session.close() }
    if modeOn { _ = session.write(Array("\u{1b}[?2027h".utf8)) }
    _ = session.write(bytes)
    _ = session.write([0x0D])
    _ = session.write(Array(repeating: 0x0A, count: 12))
    guard let block = session.scrollbackBlock() else { return nil }
    guard let row = rowContaining(bytes, in: block) else { return nil }
    guard let snapPtr = session.snapshot(), let vp = session.viewportState() else { return nil }
    defer { laban_snapshot_destroy(snapPtr) }
    let snap = snapPtr.pointee
    let cols = Int(snap.cols)
    let sel = TerminalSelection(
      sessionId: session.id,
      anchor: TerminalCellCoordinate(row: row - vp.viewportOffset, col: 0),
      focus: TerminalCellCoordinate(row: row - vp.viewportOffset, col: cols - 1)
    )
    return sel.selectedText(from: session, viewportSnapshot: snap, viewportState: vp)
  }

  private func rowContaining(_ needleBytes: [UInt8], in block: ScrollbackBlock) -> Int? {
    let textBytes = Array(block.text.utf8)
    for row in 0..<block.rowOffsets.count {
      let start = block.rowOffsets[row]
      let end = (row + 1 < block.rowOffsets.count) ? block.rowOffsets[row + 1] : textBytes.count
      guard start <= end, end <= textBytes.count else { continue }
      let slice = Array(textBytes[start..<end])
      if containsSubsequence(slice, needleBytes) { return row }
    }
    return nil
  }

  private func containsSubsequence(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
    guard !needle.isEmpty, haystack.count >= needle.count else { return false }
    for i in 0...(haystack.count - needle.count)
    where Array(haystack[i..<i + needle.count]) == needle {
      return true
    }
    return false
  }

  private func hex(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02X", $0) }.joined()
  }

  // MARK: - Diagnostic: prints the full measured table (run once, then pin)

  func testMeasure_printConformanceTable() throws {
    print("M4 CONFORMANCE TABLE (measured) ----------------------------------------")
    for c in cases {
      // OFF grid
      let off = try makeSession()
      _ = off.write(c.bytes)
      let offRow = occupiedRow0(off)
      off.close()
      // ON grid
      let on = try makeSession()
      _ = on.write(Array("\u{1b}[?2027h".utf8))
      _ = on.write(c.bytes)
      let onRow = occupiedRow0(on)
      on.close()

      let offLayout = (offRow?.cells ?? []).map { Wide(rawValue: $0.wide)?.description ?? "?(\($0.wide))" }
      let onLayout = (onRow?.cells ?? []).map { Wide(rawValue: $0.wide)?.description ?? "?(\($0.wide))" }
      let offCpr = try cprColumnAfter(c.bytes, modeOn: false)
      let onCpr = try cprColumnAfter(c.bytes, modeOn: true)

      // Scrollback find columns
      let offBlock = try scrollbackFor(c.bytes, modeOn: false)
      let onBlock = try scrollbackFor(c.bytes, modeOn: true)
      let offFind = offBlock.flatMap { firstMatchEnd(c.string, in: $0) }
      let onFind = onBlock.flatMap { firstMatchEnd(c.string, in: $0) }
      let offCopy = try copyScrolledOffRow(c.bytes, modeOn: false)
      let onCopy = try copyScrolledOffRow(c.bytes, modeOn: true)

      print("M4 [\(c.name)] bytes=\(hex(c.bytes))")
      print(
        "M4   OFF grid=\(offLayout.joined()) adv=\(offRow?.cursorCol ?? -1) cpr=\(offCpr ?? -1) "
          + "findEnd=\(offFind.map(String.init) ?? "nil") copyHex=\(offCopy.map { hex(Array($0.utf8)) } ?? "nil")")
      print(
        "M4   ON  grid=\(onLayout.joined()) adv=\(onRow?.cursorCol ?? -1) cpr=\(onCpr ?? -1) "
          + "findEnd=\(onFind.map(String.init) ?? "nil") copyHex=\(onCopy.map { hex(Array($0.utf8)) } ?? "nil") "
          + "graphemeWidths=\(onBlock?.graphemeWidths != nil ? "present" : "nil")")
    }
    print("M4 -------------------------------------------------------------------")
  }

  private func firstMatchEnd(_ needle: String, in block: ScrollbackBlock) -> Int? {
    let matches = TerminalFind.search(needle: needle, in: block)
    guard let row = rowContaining(Array(needle.utf8), in: block),
      let m = matches.first(where: { $0.row == row })
    else { return nil }
    return m.endColumn
  }

  private func firstMatch(_ needle: String, in block: ScrollbackBlock) -> TerminalFindMatch? {
    let matches = TerminalFind.search(needle: needle, in: block)
    guard let row = rowContaining(Array(needle.utf8), in: block) else { return nil }
    return matches.first(where: { $0.row == row })
  }

  // MARK: - Grid layout + cursor advance (both modes)

  func testGridLayoutAndAdvance() throws {
    for c in cases {
      // OFF
      let off = try makeSession()
      _ = off.write(c.bytes)
      guard let offRow = occupiedRow0(off) else {
        XCTFail("OFF snapshot \(c.name)"); off.close(); continue
      }
      off.close()
      XCTAssertEqual(
        offRow.cells.map { $0.wide }, c.offLayout.map { $0.rawValue },
        "OFF \(c.name): wide layout")
      XCTAssertEqual(offRow.cursorCol, c.offAdvance, "OFF \(c.name): cursor advance")

      // ON
      let on = try makeSession()
      _ = on.write(Array("\u{1b}[?2027h".utf8))
      _ = on.write(c.bytes)
      guard let onRow = occupiedRow0(on) else {
        XCTFail("ON snapshot \(c.name)"); on.close(); continue
      }
      on.close()
      XCTAssertEqual(
        onRow.cells.map { $0.wide }, c.onLayout.map { $0.rawValue },
        "ON \(c.name): wide layout")
      XCTAssertEqual(onRow.cursorCol, c.onAdvance, "ON \(c.name): cursor advance")
    }
  }

  /// The engine's `CSI 6n` cursor report must agree with `cursor_col` advance
  /// (1-based column == advance + 1, printing starts at column 1). This is the
  /// authoritative cross-check: grid width must equal what a program is told.
  func testCursorReportAgreesWithAdvance() throws {
    for c in cases {
      let offCol = try cprColumnAfter(c.bytes, modeOn: false)
      XCTAssertEqual(offCol, c.offAdvance + 1, "OFF \(c.name): CSI 6n == advance+1")
      let onCol = try cprColumnAfter(c.bytes, modeOn: true)
      XCTAssertEqual(onCol, c.onAdvance + 1, "ON \(c.name): CSI 6n == advance+1")
    }
  }

  // MARK: - Scrollback find column (both modes)

  func testScrollbackFindColumns() throws {
    for c in cases {
      guard let offBlock = try scrollbackFor(c.bytes, modeOn: false) else {
        XCTFail("OFF scrollback \(c.name)"); continue
      }
      guard let offMatch = firstMatch(c.string, in: offBlock) else {
        XCTFail("OFF find \(c.name) not found"); continue
      }
      XCTAssertEqual(offMatch.startColumn, 0, "OFF \(c.name): find start col")
      XCTAssertEqual(offMatch.endColumn, c.offFindEndColumn, "OFF \(c.name): find end col")

      guard let onBlock = try scrollbackFor(c.bytes, modeOn: true) else {
        XCTFail("ON scrollback \(c.name)"); continue
      }
      XCTAssertNotNil(onBlock.graphemeWidths, "ON \(c.name): engine width metadata carried")
      guard let onMatch = firstMatch(c.string, in: onBlock) else {
        XCTFail("ON find \(c.name) not found"); continue
      }
      XCTAssertEqual(onMatch.startColumn, 0, "ON \(c.name): find start col")
      XCTAssertEqual(onMatch.endColumn, c.onFindEndColumn, "ON \(c.name): find end col")
    }
  }

  // MARK: - Scrollback copy bytes (both modes)

  /// Copy must return the exact cluster bytes regardless of mode — copy carries
  /// text, not width, so both modes yield the same input bytes for the row.
  func testScrollbackCopyBytes() throws {
    for c in cases {
      guard let offCopy = try copyScrolledOffRow(c.bytes, modeOn: false) else {
        XCTFail("OFF copy \(c.name)"); continue
      }
      XCTAssertEqual(Array(offCopy.utf8), c.bytes, "OFF \(c.name): copy bytes")
      guard let onCopy = try copyScrolledOffRow(c.bytes, modeOn: true) else {
        XCTFail("ON copy \(c.name)"); continue
      }
      XCTAssertEqual(Array(onCopy.utf8), c.bytes, "ON \(c.name): copy bytes")
    }
  }

  // MARK: - End-to-end handshake demo (automated stand-in for the manual transcript)

  /// The automated stand-in for the manual `Artifacts and Notes` transcript: it
  /// runs the exact negotiation a real TUI performs and pins the bytes Laban
  /// replies plus the resulting cursor column. A human reproduces the same flow
  /// with the documented `printf` snippet against an installed build.
  ///
  /// Sequence (one real fixture session, mode 2027 starts OFF by default):
  ///   1. `ESC [ ? 2027 $ p`  (DECRQM while OFF)   -> expect `ESC [ ? 2027 ; 2 $ y`
  ///   2. `ESC [ ? 2027 h`    (DECSET — enable)    -> no reply
  ///   3. `ESC [ ? 2027 $ p`  (DECRQM while ON)    -> expect `ESC [ ? 2027 ; 1 $ y`
  ///   4. print farmer 👩‍🌾 then `ESC [ 6 n`       -> expect `ESC [ 1 ; 3 R` (col 3)
  /// Column 3 == the cursor after a 2-cell cluster printed at column 1, i.e. the
  /// emoji occupied exactly 2 columns under mode 2027.
  func testHandshakeDemo_negotiateThenPrintFarmer() throws {
    // Farmer = U+1F9D1 U+200D U+1F33E (derive bytes from scalars).
    let farmer: [UInt8] = {
      var v = String.UnicodeScalarView()
      v.append(Unicode.Scalar(0x1F9D1)!)
      v.append(Unicode.Scalar(0x200D)!)
      v.append(Unicode.Scalar(0x1F33E)!)
      return Array(String(v).utf8)
    }()

    let session = try makeSession()
    defer { session.close() }

    // 1. DECRQM while OFF -> RESET (2).
    _ = session.write(Array("\u{1b}[?2027$p".utf8))
    let offReply = session.drainResponse()
    XCTAssertEqual(
      offReply, Array("\u{1b}[?2027;2$y".utf8),
      "DECRQM before negotiation must report RESET (2); got \(hex(offReply))")

    // 2. Enable. 3. DECRQM while ON -> SET (1).
    _ = session.write(Array("\u{1b}[?2027h".utf8))
    _ = session.write(Array("\u{1b}[?2027$p".utf8))
    let onReply = session.drainResponse()
    XCTAssertEqual(
      onReply, Array("\u{1b}[?2027;1$y".utf8),
      "DECRQM after DECSET must report SET (1); got \(hex(onReply))")

    // 4. Print farmer, then CSI 6n -> cursor at column 3 (advanced exactly 2).
    _ = session.write(farmer)
    _ = session.write(Array("\u{1b}[6n".utf8))
    let cpr = session.drainResponse()
    XCTAssertEqual(
      cpr, Array("\u{1b}[1;3R".utf8),
      "after a mode-2027 farmer the cursor report must be ESC[1;3R (col 3 = 2-cell "
        + "cluster printed at col 1); got \(hex(cpr))")
  }

  // MARK: - Mutation-check anchor (Review Gate)

  /// Pins the ON expected widths as hard literals so a mutation that flips an ON
  /// value to its OFF value fails exactly that case. We assert the per-case ON vs
  /// OFF find columns DIFFER for the cases where clustering changes width — if a
  /// consumer regressed onto the legacy scalar path, the ON column would equal the
  /// OFF column and this guard would fire.
  func testMutationGuard_onWidthsDifferFromOffWhereClusteringApplies() throws {
    let clusteringChangesWidth = cases.filter { $0.offFindEndColumn != $0.onFindEndColumn }
    XCTAssertFalse(
      clusteringChangesWidth.isEmpty,
      "expected at least one case where mode 2027 changes the find width")
    for c in clusteringChangesWidth {
      guard let onBlock = try scrollbackFor(c.bytes, modeOn: true),
        let onMatch = firstMatch(c.string, in: onBlock)
      else {
        XCTFail("ON scrollback/find \(c.name)"); continue
      }
      XCTAssertEqual(onMatch.endColumn, c.onFindEndColumn, "ON \(c.name): pinned ON width")
      XCTAssertNotEqual(
        onMatch.endColumn, c.offFindEndColumn,
        "ON \(c.name): clustered width must differ from the legacy OFF width — "
          + "equality here means a consumer regressed to the per-scalar table")
    }
  }
}
